defmodule Jocker.Engine.Config do
  require Logger
  use Agent

  @default_config_path "/usr/local/etc/jocker_config.yaml"

  def start_link([]) do
    Agent.start_link(&initialize/0, name: __MODULE__)
  end

  def get(key) do
    Agent.get(__MODULE__, fn config -> Map.get(config, key) end)
  end

  def put(key, value) do
    Agent.update(__MODULE__, fn config -> Map.put(config, key, value) end)
  end

  def delete(key) do
    Agent.update(__MODULE__, fn config -> Map.delete(config, key) end)
  end

  defp initialize() do
    cfg = open_config_file()

    mountpoint = valid_dataset_or_exit(cfg, "zroot", true)
    Map.put(cfg, "base_layer_mountpoint", mountpoint)
    valid_dataset_or_exit(cfg, "volume_root", false)
    valid_dataset_or_exit(cfg, "base_layer_dataset", false)
    cfg = valid_snapshot_or_create(cfg, "base_layer_dataset")
    validate_default_subnet(cfg)
    validate_loopback_name(cfg)
    cfg
  end

  defp validate_loopback_name(cfg) do
    case Jocker.Engine.Network.is_valid_interface_name?(cfg["default_loopback_name"]) do
      true -> :ok
      false -> Logger.error("the default loopback if name in the configuration file is not valid")
    end
  end

  defp validate_default_subnet(cfg) do
    case CIDR.is_cidr?(cfg["default_subnet"]) do
      true -> :ok
      false -> Logger.error("the default subnet in the configuration file is not valid")
    end
  end

  defp valid_snapshot_or_create(cfg, dataset_type) do
    snapshot = Map.get(cfg, dataset_type) <> "@jocker"

    case zfs_list_mountpoint(snapshot) do
      {_, 0} -> :ok
      {_, 1} -> 0 = Jocker.Engine.ZFS.snapshot(snapshot)
    end

    Map.put(cfg, "base_layer_snapshot", snapshot)
  end

  defp valid_dataset_or_exit(cfg, dataset_type, fail_no_mountpoint) do
    path = Map.get(cfg, dataset_type)

    case zfs_list_mountpoint(path) do
      {"none\n", 0} ->
        if fail_no_mountpoint do
          Logger.error(
            "the configured zroot-dataset '#{path}' did not have any mountpoint which is needed, exiting."
          )

          exit(:normal)
        end

      {mountpoint_n, 0} ->
        String.trim(mountpoint_n)

      {_, 1} ->
        Logger.error("the configured zroot-dataset '#{path}' could not be found, exiting")
        exit(:normal)
    end
  end

  defp zfs_list_mountpoint(path) do
    System.cmd("zfs", ["list", "-H", "-o", "mountpoint", path], stderr_to_stdout: true)
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
