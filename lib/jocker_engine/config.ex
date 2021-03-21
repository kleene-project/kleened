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
    initialize_system()
    cfg = open_config_file()
    error_if_not_defined(cfg, "zroot")
    error_if_not_defined(cfg, "api_socket")
    error_if_not_defined(cfg, "base_layer_dataset")
    error_if_not_defined(cfg, "default_subnet")
    valid_subnet_or_exit(cfg["default_subnet"])
    cfg = valid_api_socket(cfg)
    cfg = initialize_jocker_root(cfg)
    cfg = initialize_baselayer(cfg)
    cfg = Map.put(cfg, "metadata_db", Path.join(["/", cfg["zroot"], "metadata.sqlite"]))
    Map.put(cfg, "pf_config_path", Path.join(["/", cfg["zroot"], "pf_jocker.conf"]))
  end

  def initialize_system() do
    loader_conf = "/boot/loader.conf"

    if not kmod_loaded?("zfs") do
      {:error, "zfs module not loaded"}
    end

    if not kmod_loaded?("pf") do
      kmod_load_or_error("pf")
    end

    if not sysrc_enabled?("pf_load", loader_conf) do
      sysrc_enable_or_error("pf_load", loader_conf)
    end

    if not sysrc_enabled?("pf_enable") do
      sysrc_enable_or_error("pf_enable")
    end

    if not sysrc_enabled?("pflog_enable") do
      sysrc_enable_or_error("pflog_enable")
    end
  end

  defp kmod_loaded?(module) do
    case System.cmd("/sbin/kldstat", ["-m", module], stderr_to_stdout: true) do
      {_, 0} -> true
      {_, 1} -> false
    end
  end

  def kmod_load_or_error(module) do
    case System.cmd("/sbin/kldload", [module], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {reason, _} -> init_error(reason)
    end
  end

  defp sysrc_enabled?(service, file \\ "/etc/rc.conf") do
    case System.cmd("/usr/sbin/sysrc", ["-n", "-f", file, service], stderr_to_stdout: true) do
      {"YES\n", 0} -> true
      _ -> false
    end
  end

  defp sysrc_enable_or_error(service, file \\ "/etc/rc.conf") do
    case System.cmd("/usr/sbin/sysrc", ["-n", "-f", file, "#{service}=\"YES\""],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {reason, _} -> init_error(reason)
    end
  end

  def error_if_not_defined(cfg, key) do
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

  defp valid_api_socket(%{"api_socket" => api_socket} = config) do
    case Jocker.Engine.Utils.decode_socket_address(api_socket) do
      {:error, error} ->
        config_error("failed to decode 'api_socket': #{inspect(error)}")

      {:hostname, _, _} ->
        config_error("failed to decode 'api_socket': #{api_socket}")

      {_type, _ipv4_address, _port} = socket ->
        Map.put(config, "api_socket", socket)
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
    raise "failed to configure jockerd"
  end

  defp init_error(msg) do
    Logger.error("initialization error: #{msg}")
    raise "failed to initialize jockerd"
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
