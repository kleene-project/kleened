defmodule Jocker.Engine.Config do
  alias Jocker.Engine.ZFS
  require Logger
  use Agent

  @default_config_path "/usr/local/etc/jocker_config.yaml"

  def start_link([]) do
    Agent.start_link(&initialize/0, name: __MODULE__)
  end

  def get(key, default \\ nil) do
    Agent.get(__MODULE__, fn config -> Map.get(config, key, default) end)
  end

  def put(key, value) do
    Agent.update(__MODULE__, fn config -> Map.put(config, key, value) end)
  end

  def delete(key) do
    Agent.update(__MODULE__, fn config -> Map.delete(config, key) end)
  end

  defp initialize() do
    cfg = open_config_file()
    exit_if_not_defined(cfg, "zroot")
    exit_if_not_defined(cfg, "api_socket")
    exit_if_not_defined(cfg, "base_layer_dataset")
    exit_if_not_defined(cfg, "default_subnet")
    cfg = initialize_jocker_root(cfg)
    cfg = initialize_baselayer(cfg)
    valid_subnet_or_exit(cfg["default_subnet"])
    cfg = Map.put(cfg, "metadata_db", Path.join(["/", cfg["zroot"], "metadata.sqlite"]))
    Map.put(cfg, "pf_config_path", Path.join(["/", cfg["zroot"], "pf_jocker.conf"]))
  end

  def exit_if_not_defined(cfg, key) do
    case Map.get(cfg, key) do
      nil -> config_error("'#{key}' key not set in configuration file. Exiting.")
      _ -> :ok
    end
  end

  defp initialize_jocker_root(cfg) do
    root = Map.get(cfg, "zroot")
    root_status = ZFS.info(root)

    case root_status do
      %{"exists?" => false} ->
        config_error("jockers root zfs filesystem #{root} does not seem to exist. Exiting.")

      %{"mountpoint" => nil} ->
        config_error("jockers root zfs filesystem #{root} does not have any mountpoint. Exiting.")

      _ ->
        :ok
    end

    create_dataset_if_not_exist(Path.join([root, "image"]))
    create_dataset_if_not_exist(Path.join([root, "container"]))
    create_dataset_if_not_exist(Path.join([root, "volumes"]))
    cfg = Map.put(cfg, "volume_root", Path.join([root, "volumes"]))
    Map.put(cfg, "base_layer_mountpoint", root_status[:mountpoint])
  end

  defp initialize_baselayer(cfg) do
    dataset = cfg["base_layer_dataset"]
    snapshot = cfg["base_layer_dataset"] <> "@jocker"
    info = ZFS.info(cfg["base_layer_dataset"])
    snapshot_info = ZFS.info(snapshot)

    cond do
      info[:exists?] == false ->
        config_error("jockers root zfs filesystem #{dataset} does not seem to exist. Exiting.")

      snapshot_info[:exists?] == false ->
        Jocker.Engine.ZFS.snapshot(snapshot)

      true ->
        :ok
    end

    Map.put(cfg, "base_layer_snapshot", snapshot)
  end

  defp create_dataset_if_not_exist(dataset) do
    case ZFS.info(dataset) do
      %{:exists? => true} -> :ok
      %{:exists? => false} -> ZFS.create(dataset)
    end
  end

  defp valid_subnet_or_exit(subnet) do
    case CIDR.is_cidr?(subnet) do
      true -> :ok
      false -> config_error("Invalid 'default_subnet' in the configuration file.")
    end
  end

  defp config_error(msg) do
    Logger.error("configuration error: #{msg}")
    exit(:normal)
  end

  defp open_config_file() do
    case YamlElixir.read_from_file(@default_config_path) do
      {:ok, config} ->
        case valid_config?(config) do
          :yes ->
            config

          :no ->
            Logger.warn("config file did not contain a valid configuration")
            %{}
        end

      other_msg ->
        Logger.warn(
          "there was an error when trying to open #{@default_config_path} #{inspect(other_msg)}"
        )

        %{}
    end
  end

  defp valid_config?(config) do
    case is_map(config) do
      true -> :yes
      false -> :no
    end
  end
end
