defmodule Kleened.Core.Config do
  alias Kleened.Core.ZFS
  require Logger
  use Agent

  @default_config_path "/usr/local/etc/kleened/config.yaml"

  def initialize_host(options) do
    loader_conf = "/boot/loader.conf"
    rc_conf = "/etc/rc.conf"

    ensure_kmod_loaded("zfs", options)
    ensure_kmod_loaded("pf", options)
    ensure_kmod_loaded("pflog", options)

    ensure_sysrc_enabled("zfs_load", loader_conf, options)
    ensure_sysrc_enabled("zfs_enable", rc_conf, options)

    ensure_sysrc_enabled("pf_load", loader_conf, options)
    ensure_sysrc_enabled("pf_enable", rc_conf, options)
    ensure_sysrc_enabled("pflog_enable", rc_conf, options)

    cfg = open_config_file()
    error_if_not_defined(cfg, "kleene_root")
    initialize_kleene_root(cfg)

    ensure_rctl()
  end

  def bootstrap() do
    cfg = open_config_file()
    initialize_logging(cfg)
    error_if_not_defined(cfg, "kleene_root")
    error_if_not_defined(cfg, "api_listening_sockets")
    error_if_not_defined(cfg, "pf_config_path")
    error_if_not_defined(cfg, "pf_config_template_path")
    error_if_not_defined(cfg, "enable_logging")
    error_if_not_defined(cfg, "log_level")
    add_api_listening_options(cfg, [])
  end

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
    root = Map.get(cfg, "kleene_root")
    cfg = Map.put(cfg, "container_root", Path.join([root, "container"]))
    cfg = Map.put(cfg, "image_root", Path.join([root, "image"]))
    cfg = Map.put(cfg, "volume_root", Path.join([root, "volumes"]))
    Map.put(cfg, "metadata_db", Path.join(["/", cfg["kleene_root"], "metadata.sqlite"]))
  end

  defp initialize_logging(config) do
    if config["enable_logging"] do
      :logger.add_handlers(:kleened)
    end

    log_levels =
      MapSet.new(["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"])

    if MapSet.member?(log_levels, config["log_level"]) do
      log_level = String.to_existing_atom(config["log_level"])
      Logger.configure(level: log_level)
    end
  end

  defp ensure_kmod_loaded(module, %{dry_run: dry_run}) do
    IO.write("Verifying kernel module #{module} is loaded...")

    if not kmod_loaded?(module) do
      IO.write("not loaded, trying to load..")

      if not dry_run do
        kmod_load_or_error(module)
      end
    end

    IO.puts("OK")
  end

  defp ensure_sysrc_enabled(service, file, %{dry_run: dry_run}) do
    IO.write("Verifying if '#{service}' is set to \"YES\" in #{file}...")

    if not sysrc_enabled?(service, file) do
      IO.write("not enabled, enabling...")

      if not dry_run do
        sysrc_enable_or_error(service, file)
      end
    end

    IO.puts("OK")
  end

  defp ensure_rctl() do
    IO.write("Verifying rctl is enabled...")

    if rctl_loaded?() do
      IO.puts("OK")
    else
      IO.puts("error!")
      IO.puts("Rctl does not seem to be enabled, so container resource limiting will not work.")

      IO.puts(
        "Set kern.racct.enable=1 in /boot/loader.conf and reboot the system to enable rctl."
      )
    end
  end

  def rctl_loaded?() do
    detect_racct_cmd = "/bin/cat /boot/loader.conf | grep kern.racct.enable"

    case System.cmd("/bin/sh", ["-c", detect_racct_cmd]) do
      {<<"kern.racct.enable=", value::binary>>, 0} ->
        case String.trim(value) |> String.trim("\"") do
          "1" -> true
          _ -> false
        end

      {_, _nonzero_exit} ->
        false
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

  defp sysrc_enabled?(service, file) do
    case System.cmd("/usr/sbin/sysrc", ["-n", "-f", file, service], stderr_to_stdout: true) do
      {"YES\n", 0} -> true
      _ -> false
    end
  end

  defp sysrc_enable_or_error(service, file) do
    case System.cmd("/usr/sbin/sysrc", ["-n", "-f", file, "#{service}=\"YES\""],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {reason, _} ->
        init_error(reason)
    end
  end

  def error_if_not_defined(cfg, key) do
    case Map.get(cfg, key) do
      nil -> config_error("'#{key}' key not set in configuration file. Exiting.")
      _ -> :ok
    end
  end

  defp initialize_kleene_root(cfg) do
    root = Map.get(cfg, "kleene_root")
    create_dataset_if_not_exist(root)

    root_status = ZFS.info(root)

    case root_status do
      %{"mountpoint" => nil} ->
        msg =
          "kleened's root zfs filesystem #{root} does not have any mountpoint. Please set it manually."

        init_error(msg)

      _ ->
        :ok
    end

    create_dataset_if_not_exist(Path.join([root, "image"]))
    create_dataset_if_not_exist(Path.join([root, "container"]))
    create_dataset_if_not_exist(Path.join([root, "volumes"]))
  end

  defp create_dataset_if_not_exist(dataset) do
    IO.write("Verifying if zfs dataset #{dataset} exists...")

    if not ZFS.exists?(dataset) do
      IO.write("does not exist, creating...")

      case ZFS.cmd("create #{dataset}", %{suppress_logging: true}) do
        {_, 0} ->
          :ok

        {reason, _nonzero_exit} ->
          init_error("could not create ZFS dataset #{dataset}: #{reason}")
      end
    end

    IO.puts("OK")
  end

  defp add_api_listening_options(
         %{"api_listening_sockets" => [api_socket | rest]} = config,
         listeners
       )
       when is_map(api_socket) do
    address = URI.parse(api_socket["address"])

    # General validation that the URI is relevant for kleened
    case address do
      %URI{
        userinfo: nil,
        query: nil,
        fragment: nil
      } ->
        :ok

      _ ->
        config_error("could not verify proper value of 'address': #{inspect(address)}")
    end

    # Remove root path if it exists in tcp-sockets and remove empty hostname i so
    address =
      case address do
        %URI{path: "/"} ->
          %URI{address | path: nil}

        _ ->
          address
      end

    # Extract specific listening scenarios (and config_error'ing if it fails)
    listener =
      case address do
        %URI{scheme: "http", host: ip, path: nil, port: port} when is_integer(port) ->
          opts = [{:port, port} | ip_options(ip)]
          {:http, opts}

        %URI{scheme: "http", host: "", path: path} ->
          delete_file_if_exists(path)
          opts = [port: 0, ip: {:local, path}]
          {:http, opts}

        %URI{scheme: "https", host: ip, path: nil, port: port} when is_integer(port) ->
          opts = [{:port, port} | ip_options(ip)] ++ tls_options(api_socket)
          {:https, opts}

        %URI{scheme: "https", host: "", path: path} ->
          delete_file_if_exists(path)
          opts = [port: 0, ip: {:local, path}] ++ tls_options(api_socket)
          {:https, opts}

        _ ->
          config_error(
            "Failed to extract correct information from socket URI: #{inspect(address)}"
          )
      end

    add_api_listening_options(Map.put(config, "api_listening_sockets", rest), [
      listener | listeners
    ])
  end

  defp add_api_listening_options(
         %{"api_listening_sockets" => []},
         listeners
       ) do
    listeners
  end

  defp add_api_listening_options(_config, _listeners) do
    config_error("could not parse value of 'api_listening_sockets'")
  end

  def ip_options(ip) do
    ip_charlist = String.to_charlist(ip)

    case :inet.parse_address(ip_charlist) do
      {:ok, ip_v4} when tuple_size(ip_v4) == 4 ->
        [net: :inet, ip: ip_v4]

      {:ok, ip_v6} when tuple_size(ip_v6) == 8 ->
        [net: :inet6, ip: ip_v6]

      error ->
        config_error("Error parsing ip-address in 'api_socket': #{inspect(error)}")
    end
  end

  def tls_options(config) do
    []
    |> parse_tls_file_option(config, :certfile)
    |> parse_tls_file_option(config, :keyfile)
    |> parse_tls_file_option(config, :dhfile)
    |> parse_tls_file_option(config, :cacertfile)
    |> parse_tls_verify_option(config)
  end

  def parse_tls_file_option(options, config, name) do
    name_string =
      cond do
        name == :certfile -> "tlscert"
        name == :keyfile -> "tlskey"
        name == :dhfile -> "tlsdh"
        name == :cacertfile -> "tlscacert"
      end

    tls_option =
      case Map.get(config, name_string) do
        nil ->
          options

        path ->
          case File.exists?(path) do
            true -> [{name, path} | options]
            false -> config_error("file in '#{name_string}' does not exist.")
          end
      end

    tls_option
  end

  def parse_tls_verify_option(options, config) do
    case Map.get(config, "tlsverify") do
      nil ->
        [{:verify, :verify_none} | options]

      false ->
        [{:verify, :verify_none} | options]

      true ->
        [{:verify, :verify_peer}, {:fail_if_no_peer_cert, true} | options]

      _ ->
        config_error("'verify' options value not understood.")
    end
  end

  defp config_error(msg) do
    Logger.error("configuration error: #{msg}")
    raise RuntimeError, message: "failed to configure kleened"
  end

  defp init_error(msg) do
    Logger.error("initialization error: #{msg}")
    raise RuntimeError, message: "failed to initialize kleened"
  end

  defp open_config_file() do
    case YamlElixir.read_from_file(@default_config_path) do
      {:ok, config} ->
        case valid_config?(config) do
          :yes ->
            config

          :no ->
            Logger.warning("config file did not contain a valid configuration")
            %{}
        end

      other_msg ->
        Logger.warning(
          "an error occurred while trying to open config file #{@default_config_path}: #{
            inspect(other_msg)
          }"
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

  defp delete_file_if_exists(path) do
    case File.stat(path) do
      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        config_error("an error occurred while trying to open unix-socket #{path}: #{reason}.")

      {:ok, %File.Stat{type: :regular}} ->
        remove_socket(path)

      {:ok, %File.Stat{type: :other}} ->
        remove_socket(path)

      {:ok, %File.Stat{type: non_file}} ->
        config_error("The unix-socket path #{path} is not a file but a #{non_file}.")
    end
  end

  defp remove_socket(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, reason} ->
        config_error("an error occurred while trying to remove unix-socket #{path}: #{reason}.")
    end
  end
end
