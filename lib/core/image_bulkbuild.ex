defmodule Kleened.Core.ImageBulkBuild do
  alias Kleened.Core.{
    Container,
    Image,
    Network,
    MetaData,
    Utils
  }

  alias Kleened.API.Schemas
  alias Schemas.{ImageCreateConfig, ImageBuildConfig, ContainerConfig}

  defmodule State do
    defstruct ready_to_build: [],
              awaiting_build: [],
              failed_builds: [],
              builds_in_progress: %{},
              finished_builds: [],
              image_tree: nil,
              workers: %{},
              is_building: false,
              worker_count: 0,
              client_pid: nil
  end

  require Logger
  use GenServer

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec bulk_build([%Schemas.ImageBuildConfig{} | %Schemas.ImageCreateConfig{}], String.t()) ::
          {:ok, String.t(), pid()} | {:error, String.t()} | {:error, String.t()}
  def bulk_build(images, worker_count) do
    GenServer.call(__MODULE__, {:build, images, worker_count, self()})
  end

  def stop() do
    GenServer.call(__MODULE__, :stop)
  end

  ### Callback functions
  @impl true
  def init([]) do
    {:ok, %State{}}
  end

  defp create_image_inheritage_tree(parents) do
    image_and_parents =
      Map.to_list(parents)
      |> Enum.map(fn {image, parent} -> {parent, image} end)

    Graph.new() |> Graph.add_edges(image_and_parents)
  end

  defp is_base_image(%Schemas.ImageCreateConfig{}) do
    true
  end

  defp is_base_image(_) do
    false
  end

  @spec extract_parent_images([%Schemas.ImageBuildConfig{}]) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def extract_parent_images(images) do
    extract_parent_images(images, %{})
  end

  def extract_parent_images([], parents), do: {:ok, parents}

  def extract_parent_images([config | rest], parents) do
    case config.container_config do
      %ContainerConfig{image: nil} ->
        images = [%ImageBuildConfig{config | container_config: nil} | rest]
        extract_parent_images(images, parents)

      %ContainerConfig{image: image} ->
        parents = Map.put(parents, config.tag, image)
        extract_parent_images(rest, parents)

      nil ->
        with {:ok, instructions} <-
               Image.load_and_parse_dockerfile(config.dockerfile, config.context),
             {_, {:from, image}} <- find_from_instruction(instructions) do
          parents = Map.put(parents, config.tag, Utils.normalize_nametag(image))
          # extract_parent_images(rest, [Utils.normalize_nametag(image) | parents])
          extract_parent_images(rest, parents)
        else
          {:error, :enoent} -> {:error, "Could not open #{config.context}/#{config.dockerfile}"}
          {:error, error_msg} -> {:error, error_msg}
          nil -> {:error, "No FROM instruction found in Dockerfile"}
        end
    end
  end

  def find_from_instruction(instructions) do
    Enum.find(instructions, fn
      {_, {:from, _}} -> true
      _ -> false
    end)
  end

  @spec no_images_with_nonexisting_parents([%Schemas.ImageBuildConfig{}], [String.t()], [
          String.t()
        ]) ::
          :ok | :error
  def no_images_with_nonexisting_parents(build_images, base_images, parent_images) do
    # Check if the images to build has a parent that is either already built or going to be built
    already_built = MetaData.list_images() |> Enum.map(&"#{&1.name}:#{&1.tag}") |> MapSet.new()
    going_to_built = build_images |> Enum.map(& &1.tag) |> MapSet.new()
    base_images = base_images |> Enum.map(& &1.tag) |> MapSet.new()
    all_images = already_built |> MapSet.union(going_to_built) |> MapSet.union(base_images)
    parent_images = Map.values(parent_images)
    parent_images |> Enum.all?(&MapSet.member?(all_images, &1))
  end

  @spec partition_images([%Schemas.ImageBuildConfig{}], [String.t()]) ::
          {[%Schemas.ImageBuildConfig{}], [%Schemas.ImageBuildConfig{}]}
  defp partition_images(build_images, parent_map) do
    # Partition the images to build into two categories:
    # 1) images where their parent already exists so they can be builded straight away
    # 2) images with a parent that (also) needs to be built
    already_built = MetaData.list_images() |> Enum.map(& &1.tag) |> MapSet.new()

    Enum.split_with(build_images, fn image ->
      MapSet.member?(already_built, Map.get(parent_map, image.tag, ""))
    end)
  end

  @impl true
  def handle_call(:stop, _from, %State{builds_in_progress: builds} = state) do
    builds
    |> Map.values()
    |> Enum.map(fn image_id ->
      Container.stop(image_id)
      Container.remove(image_id)
      Image.remove(image_id)
      Network.remove("buildnet_" <> image_id)
    end)

    {:reply, :ok, state}
  end

  def handle_call({:build, _images, _, _}, _from, %State{is_building: true} = state) do
    {:reply, {:error, "bulk build already in progress"}, state}
  end

  def handle_call({:build, images, worker_count, caller}, _from, %State{is_building: false}) do
    images = images |> Enum.map(&Map.replace(&1, :tag, Utils.normalize_nametag(&1.tag)))
    base_images = Enum.filter(images, &is_base_image/1)
    build_images = Enum.reject(images, &is_base_image/1)

    case extract_parent_images(build_images) do
      {:ok, parent_images} ->
        case no_images_with_nonexisting_parents(build_images, base_images, parent_images) do
          true ->
            {images_with_existing_parent, images_with_unbuild_parent} =
              partition_images(build_images, parent_images)

            image_tree = create_image_inheritage_tree(parent_images)

            state = %State{
              awaiting_build: images_with_unbuild_parent,
              ready_to_build: base_images ++ images_with_existing_parent,
              image_tree: image_tree,
              worker_count: worker_count,
              client_pid: caller,
              is_building: true
            }

            Logger.debug("Initialized bulk-building state: #{inspect(state)}")

            {:reply, :ok, start_building(state)}

          false ->
            {:reply,
             {:error, "image build list contains images with a non-existing parent image"},
             %State{}}
        end

      {:error, reason} ->
        Logger.warning("could not start bulk-build: #{inspect(reason)}")
        {:reply, {:error, reason}, %State{}}
    end
  end

  @impl true
  def handle_info({:image_builder, pid, {:image_build_succesfully, image}}, state) do
    image_id = state.builds_in_progress[pid]
    msg = "#{image_id}: succesfully built image with nametag #{image.name}:#{image.tag}"
    send_msg(msg, state)
    handle_build_success(pid, image, state)
  end

  def handle_info({:image_builder, pid, {:image_build_failed, reason}}, state) do
    image_id = state.builds_in_progress[pid]
    msg = {:image_build_failed, "#{image_id}:#{reason}"}
    send_msg(msg, state)
    handle_build_failure(pid, state)
  end

  def handle_info({:image_builder, pid, msg}, state)
      when is_binary(msg) do
    # Status messages from the build process
    image_id = state.builds_in_progress[pid]
    msg = "#{image_id}:#{msg}"
    send_msg(msg, state)
    {:noreply, state}
  end

  # message from image_create.ex
  def handle_info({:image_creator, pid, {:ok, image}}, state) do
    image_id = state.builds_in_progress[pid]
    msg = "#{image_id}:succesfully created image with nametag #{image.name}:#{image.tag}\n"
    send_msg(msg, state)
    handle_build_success(pid, image, state)
  end

  def handle_info({:image_creator, pid, {:error, reason}}, state) do
    Logger.info("image creation failed: #{reason}")
    image_id = state.builds_in_progress[pid]
    reason = "#{image_id}:#{reason}"
    send_msg({:image_creator_failed, {:error, reason}}, state)
    handle_build_failure(pid, state)
  end

  def handle_info({:image_creator, pid, {:info, msg}}, state) do
    image_id = state.builds_in_progress[pid]
    msg = "#{image_id}:#{msg}"
    send_msg({:info, msg}, state)
    {:noreply, state}
  end

  def handle_info({:image_builder, pid, {:jail_output, output}}, state) do
    image_id = state.builds_in_progress[pid]
    msg = {:jail_output, "#{image_id}:#{output}"}
    send_msg(msg, state)
    {:noreply, state}
  end

  # Handles successful image build
  defp handle_build_success(pid, image, state) do
    state = update_build_state(image, pid, state)

    case state.ready_to_build do
      [] ->
        # send_msg(msg, state)
        Logger.notice("Deployment build complete")
        send_msg({:deployment_build_complete, state.finished_builds}, state)
        {:noreply, %State{}}

      _images_to_build ->
        {:noreply, start_building(state)}
    end
  end

  defp update_build_state(image, pid, state) do
    nametag = "#{image.name}:#{image.tag}"
    ready_to_build_tags = Graph.out_neighbors(state.image_tree, nametag)
    {ready, updated_await} = update_ready_to_build(ready_to_build_tags, state.awaiting_build)

    %State{
      state
      | awaiting_build: updated_await,
        ready_to_build: state.ready_to_build ++ ready,
        builds_in_progress: Map.drop(state.builds_in_progress, [pid]),
        finished_builds: [image | state.finished_builds],
        workers: Map.drop(state.workers, [pid])
    }
  end

  # Handles failed image build
  defp handle_build_failure(pid, state) do
    # We stop processing images to be built/created
    state = %State{
      state
      | workers: Map.drop(state.workers, [pid]),
        builds_in_progress: Map.drop(state.builds_in_progress, [pid]),
        ready_to_build: []
    }

    case state.ready_to_build do
      [] ->
        # send_msg(msg, state)
        send_msg({:deployment_build_complete, state.finished_builds}, state)
        {:noreply, %State{}}

      _images_to_build ->
        %State{state | worker_count: 0}
        {:noreply, state}
    end
  end

  defp start_building(state) do
    build_limit_reached = :maps.size(state.workers) == state.worker_count

    case {build_limit_reached, state.ready_to_build} do
      {true, _} ->
        state

      {false, []} ->
        state

      {false, [%ImageCreateConfig{} = next | rest]} ->
        {:ok, image_id, pid} = Kleened.Core.ImageCreate.create(next)

        state = %{
          state
          | builds_in_progress: Map.put(state.builds_in_progress, pid, image_id),
            workers: Map.put(state.workers, pid, next),
            ready_to_build: rest
        }

        start_building(state)

      {false, [%Schemas.ImageBuildConfig{} = next | rest]} ->
        case Kleened.Core.Image.build(next) do
          {:ok, image_id, pid} ->
            state = %{
              state
              | builds_in_progress: Map.put(state.builds_in_progress, pid, image_id),
                workers: Map.put(state.workers, pid, next),
                ready_to_build: rest
            }

            start_building(state)

          {:error, _} ->
            failed = [next | state.failed_builds]
            %{state | ready_to_build: rest, failed_builds: failed}
        end
    end
  end

  @spec update_ready_to_build([String.t()], [%Schemas.ImageBuildConfig{}]) ::
          {[%Schemas.ImageBuildConfig{}], [%Schemas.ImageBuildConfig{}]}
  defp update_ready_to_build(ready_to_build_tags, awaiting_to_build) do
    tags = MapSet.new(ready_to_build_tags)

    ready_to_build_images =
      awaiting_to_build |> Enum.filter(&MapSet.member?(tags, &1.tag))

    awaiting_to_build_updated =
      awaiting_to_build |> Enum.filter(&(not MapSet.member?(tags, &1.tag)))

    {ready_to_build_images, awaiting_to_build_updated}
  end

  defp send_msg(msg, state) do
    full_msg = {:image_bulkbuilder, self(), msg}
    :ok = Process.send(state.client_pid, full_msg, [])
  end
end
