defmodule Jocker.MetaData do
  alias Jocker.Config
  use GenServer
  use Amnesia
  require Config
  require Record

  Record.defrecord(:layer,
    id: :none,
    parent_id: :none,
    dataset: :none,
    snapshot: :none,
    mountpoint: :none
  )

  Record.defrecord(:image,
    id: :none,
    name: :none,
    tag: :none,
    layer: :none,
    command: :none,
    user: "root",
    created: :none
  )

  Record.defrecord(:container,
    id: :none,
    name: :none,
    running: :none,
    pid: :none,
    command: :none,
    layer: :none,
    ip: :none,
    image_id: :none,
    parameters: [],
    created: :none
  )

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def add_container(container) do
    Amnesia.transaction(fn -> Amnesia.Table.write(:container, container) end)
  end

  def add_image(image(name: new_name, tag: new_tag) = new_img) do
    match_all = image(_: :_)
    match = image(match_all, name: new_name, tag: new_tag)
    result = [:"$_"]
    matchspec = [{match, [], result}]

    Amnesia.transaction do
      case Amnesia.Table.select(:image, matchspec) do
        [existing_img] ->
          Amnesia.Table.write(:image, image(existing_img, name: :none, tag: :none))

        nil ->
          :ok
      end

      Amnesia.Table.write(:image, new_img)
    end
  end

  def get_image(id_or_tag) do
    Amnesia.transaction do
      case Amnesia.Table.read(:image, id_or_tag) do
        [image] ->
          image

        nil ->
          {name, tag} = Jocker.Utils.decode_tagname(id_or_tag)
          match_all = image(_: :_)
          match = image(match_all, name: name, tag: tag)
          matchspec = [{match, [], [:"$_"]}]

          case Amnesia.Table.select(:image, matchspec) do
            nil ->
              :not_found

            result ->
              extract(result)
          end
      end
    end
  end

  def list_images() do
    match_all = image(_: :_)
    match = image(match_all, id: :"$1")
    guard = [{:"=/=", :"$1", "base"}]
    matchspec = [{match, guard, [:"$_"]}]

    result = Amnesia.transaction(fn -> Amnesia.Table.select(:image, matchspec) end)
    sort_images(extract(result))
  end

  def list_containers() do
    match = :_
    matchspec = [{match, [], [:"$_"]}]

    result = Amnesia.transaction(fn -> Amnesia.Table.select(:container, matchspec) end)
    sort_containers(extract(result))
  end

  def list_running_containers() do
    match_all = container(_: :_)
    match = container(match_all, running: true)
    matchspec = [{match, [], [:"$_"]}]

    result = Amnesia.transaction(fn -> Amnesia.Table.select(:container, matchspec) end)
    extract(result)
  end

  def clear_tables do
    Amnesia.Table.clear(:layer)
    Amnesia.Table.clear(:image)
    Amnesia.Table.clear(:container)
    insert_base_objects()
  end

  @impl true
  def init(_) do
    IO.puts("Starting metadata genserver")
    # Initialize mnesia
    :application.set_env(:mnesia, :dir, '/' ++ to_charlist(Config.zroot()))
    Amnesia.Schema.create([])
    :application.start(:mnesia)

    # Extract record fields
    image_fields = image() |> image() |> Keyword.keys()
    container_fields = container() |> container() |> Keyword.keys()
    layer_fields = layer() |> layer() |> Keyword.keys()

    # Create tables
    Amnesia.Table.create(:image,
      attributes: image_fields,
      index: [:name],
      disc_copies: []
    )

    Amnesia.Table.create(:container,
      attributes: container_fields,
      index: [:name],
      disc_copies: []
    )

    Amnesia.Table.create(:layer,
      attributes: layer_fields,
      index: [],
      disc_copies: []
    )

    insert_base_objects()
    {:ok, :state}
  end

  defp sort_images(images) do
    Enum.sort(images, fn image(created: a), image(created: b) -> a >= b end)
  end

  defp sort_containers(containers) do
    Enum.sort(containers, fn container(created: a), container(created: b) -> a >= b end)
  end

  defp insert_base_objects do
    Amnesia.transaction do
      base_layer =
        layer(
          id: "base",
          dataset: Config.base_layer_dataset(),
          snapshot: Config.base_layer_snapshot(),
          mountpoint: Config.base_layer_mountpoint()
        )

      base_image =
        image(
          id: "base",
          tag: "base",
          layer: base_layer
        )

      Amnesia.Table.write(:layer, base_layer)
      Amnesia.Table.write(:image, base_image)
    end
  end

  defp extract(nil), do: []

  defp extract(result), do: result.values()
end
