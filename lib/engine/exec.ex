defmodule Jocker.Engine.Exec do
  alias Jocker.API.Schemas.ExecConfig
  alias Jocker.Engine.{Container, MetaData, Layer, Utils, ExecInstances}

  defmodule State do
    defstruct config: nil,
              exec_id: nil,
              subscribers: nil,
              container: :not_started,
              port: nil
  end

  require Logger
  use GenServer, restart: :transient

  @type execution_config() :: %ExecConfig{}
  @type start_options() :: %{:attach => boolean(), :start_container => boolean()}
  @type stop_options() :: %{:force_stop => boolean(), :stop_container => boolean()}
  @type container() :: %Container{}

  @type exec_id() :: String.t()
  @type container_id() :: String.t()

  @spec create(execution_config() | container_id()) :: {:ok, exec_id()} | {:error, String.t()}
  def create(container_id) when is_binary(container_id) do
    config = %ExecConfig{container_id: container_id, cmd: [], env: [], user: ""}
    create(config)
  end

  def create(%ExecConfig{container_id: container_idname} = config) do
    exec_id = Utils.uuid()

    case MetaData.get_container(container_idname) do
      %Container{id: container_id} ->
        config = %ExecConfig{config | container_id: container_id}
        name = {:via, Registry, {ExecInstances, exec_id, container_id}}
        {:ok, _pid} = GenServer.start_link(Jocker.Engine.Exec, [exec_id, config], name: name)
        Logger.debug("succesfully created new execution instance #{exec_id}")
        {:ok, exec_id}

      :not_found ->
        {:error, "conntainer not found"}
    end
  end

  @spec start(exec_id(), start_options()) :: :ok | {:error, String.t()}
  def start(exec_id, opts) do
    if opts.attach do
      call(exec_id, {:attach, self()})
    end

    call(exec_id, {:start, opts})
  end

  @spec stop(exec_id(), stop_options) :: {:ok, String.t()} | {:error, String.t()}
  def stop(exec_id, opts) do
    call(exec_id, {:stop, opts})
  end

  defp call(exec_id, command) do
    case Registry.lookup(ExecInstances, exec_id) do
      [{pid, _container_id}] ->
        GenServer.call(pid, command)

      [] ->
        {:error, "could not find a execution instance matching '#{exec_id}'"}
    end
  end

  ### ===================================================================
  ### gen_server callbacks
  ### ===================================================================
  @impl true
  def init([exec_id, config]) do
    {:ok, %State{exec_id: exec_id, config: config, subscribers: []}}
  end

  @impl true
  def handle_call({:stop, _}, _from, %State{port: nil} = state) do
    reply = {:ok, "execution instance not running, removing it anyway"}
    {:stop, :normal, reply, state}
  end

  def handle_call({:stop, %{stop_container: true}}, _from, state) do
    Logger.debug("#{state.exec_id}: stopping container")
    reply = stop_container_(state)
    await_exit_and_shutdown(reply, state)
  end

  def handle_call({:stop, %{stop_container: false} = opts}, _from, state) do
    Logger.debug("#{state.exec_id}: stopping executable")
    result = stop_executable(state, opts)
    await_exit_and_shutdown(result, state)
  end

  def handle_call({:attach, pid}, _from, %State{subscribers: subscribers} = state) do
    {:reply, :ok, %State{state | subscribers: Enum.uniq([pid | subscribers])}}
  end

  def handle_call({:start, _opts}, _from, %State{port: port} = state)
      when is_port(port) do
    reply = {:error, "executable already started"}
    {:reply, reply, state}
  end

  def handle_call({:start, %{start_container: start_container}}, _from, %State{port: nil} = state) do
    case start_(state.config, start_container) do
      {:error, _reason} = msg ->
        {:reply, msg, state}

      {:ok, port, container} when is_port(port) ->
        {:reply, :ok, %State{state | container: container, port: port}}
    end
  end

  @impl true
  def handle_info({port, {:data, jail_output}}, %State{:port => port} = state) do
    Logger.debug("#{inspect(port)} Msg from executing port: #{inspect(jail_output)}")
    relay_msg({:jail_output, jail_output}, state)
    {:noreply, state}
  end

  def handle_info(
        {port, {:exit_status, exit_code}},
        %State{port: port} = state
      ) do
    shutdown_process(exit_code, state)
    {:stop, :normal, %State{state | :port => nil}}
  end

  def handle_info(unknown_msg, state) do
    Logger.warn("Unknown message: #{inspect(unknown_msg)}")
    {:noreply, state}
  end

  @spec stop_container_(%State{}) :: {:ok, String.t()} | {:error, String.t()}
  defp stop_container_(%State{config: %{container_id: container_id}} = state) do
    case Utils.is_container_running?(container_id) do
      true ->
        Logger.debug("Shutting down jail #{container_id}")

        {output, exit_code} =
          System.cmd("/usr/sbin/jail", ["-r", container_id], stderr_to_stdout: true)

        relay_msg({:shutdown, :jail_stopped}, state)

        case {output, exit_code} do
          {output, 0} ->
            Logger.info("Stopped jail #{container_id} with exitcode #{exit_code}: #{output}")
            {:ok, "succesfully closed container"}

          {output, _} ->
            Logger.warn("Stopped jail #{container_id} with exitcode #{exit_code}: #{output}")
            msg = "/usr/sbin/jail exited abnormally with exit code #{exit_code}: '#{output}'"
            {:error, msg}
        end

      false ->
        {:error, "container not running"}
    end
  end

  @spec stop_executable(%State{}, stop_options()) :: {:ok, String.t()} | {:error, String.t()}
  defp stop_executable(state, opts) do
    jailed_process_pid = get_pid_of_jailed_process(state.port)

    cmd_args =
      case opts do
        %{force_stop: true} -> ["-9", jailed_process_pid]
        %{force_stop: false} -> [jailed_process_pid]
      end

    case System.cmd("/bin/kill", cmd_args) do
      {_, 0} ->
        {:ok, "succesfully sent termination signal to executable"}

      {output, non_zero} ->
        Logger.warn(
          "Could not kill process, kill exited with code #{non_zero} and output: #{output}"
        )

        {:error, "error closing process: #{output}"}
    end
  end

  defp await_exit_and_shutdown({:error, _msg} = reply, state) do
    {:reply, reply, state}
  end

  defp await_exit_and_shutdown({:ok, _msg} = reply, %State{port: port} = state) do
    receive do
      {^port, {:exit_status, exit_code}} ->
        shutdown_process(exit_code, state)
        {:stop, :normal, reply, %State{state | port: nil}}
    after
      5_000 ->
        {:reply, {:error, "timed out while waiting for jail to exit"}, state}
    end
  end

  defp shutdown_process(exit_code, %State{config: config, container: cont} = state) do
    case Utils.is_container_running?(config.container_id) do
      false ->
        msg =
          "#{state.exec_id}: container #{config.container_id} stopped with exit code #{exit_code}"

        Logger.debug(msg)

        jail_cleanup(cont)

        relay_msg({:shutdown, :jail_stopped}, state)

      true ->
        msg = "execution instance #{state.exec_id} stopped with exit code #{exit_code}"
        Logger.debug(msg)

        relay_msg({:shutdown, :jailed_process_exited}, state)
    end
  end

  @spec get_pid_of_jailed_process(port()) :: String.t()
  defp get_pid_of_jailed_process(port) do
    # ps --libxo json -o user,pid,ppid,command -d  -ax -p 2138
    # {"process-information":
    #   {"process": [
    #     {"user":"root","pid":"2138","ppid":"2137","command":"jail -c command=/bin/sh -c /bin/sleep 10"},
    #     {"user":"root","pid":"2139","ppid":"2138","command":"- /bin/sleep 10"}
    #   ]}
    jail_pid = port |> Port.info() |> Keyword.get(:os_pid) |> Integer.to_string()

    {jailed_processes, 0} =
      System.cmd("/bin/ps", ~w"--libxo json -o user,pid,ppid,command -d  -ax -p #{jail_pid}")

    Logger.warn("#{jail_pid} : LOL #{inspect(jailed_processes)}")

    %{"process-information" => %{"process" => processes}} = Jason.decode!(jailed_processes)

    # Locate the process that have our port (i.e. /sbin/jail) as parent.
    [jailed_pid] =
      processes
      |> Enum.filter(fn %{"pid" => pid} -> pid == jail_pid end)
      # If you are using /sbin/jail, you need to shutdown the child of the port pid:
      # |> Enum.filter(fn %{"ppid" => ppid} -> ppid == jail_pid end)
      |> Enum.map(fn %{"pid" => pid} -> pid end)

    jailed_pid
  end

  defp start_(config, start_container) do
    case MetaData.get_container(config.container_id) do
      %Container{} = cont ->
        cont = merge_configurations(cont, config)

        case {Utils.is_container_running?(cont.id), start_container} do
          {true, _} ->
            port = jexec_container(cont)
            {:ok, port, cont}

          {false, true} ->
            port = jail_start_container(cont)
            {:ok, port, cont}

          {false, false} ->
            {:error, "cannot start container when 'start_container' is false."}
        end

      :not_found ->
        {:error, "container not found"}
    end
  end

  defp merge_configurations(
         %Container{
           command: default_cmd,
           user: default_user,
           env_vars: default_env
         } = cont,
         %ExecConfig{
           cmd: exec_cmd,
           user: exec_user,
           env: exec_env
         }
       ) do
    env = Utils.merge_environment_variable_lists(default_env, exec_env)

    cmd =
      case exec_cmd do
        [] -> default_cmd
        _ -> exec_cmd
      end

    user =
      case exec_user do
        "" -> default_user
        _ -> exec_user
      end

    %Container{cont | user: user, command: cmd, env_vars: env}
  end

  defp jail_cleanup(%Container{layer_id: layer_id}) do
    %Layer{mountpoint: mountpoint} = Jocker.Engine.MetaData.get_layer(layer_id)

    # remove any devfs mounts of the jail. If it was closed with 'jail -r <jailname>' devfs should be removed automatically.
    # If the jail stops because there jailed process stops (i.e. 'jail -c <etc> /bin/sleep 10') then devfs is NOT removed.
    # A race condition can also occur such that "jail -r" does not unmount before this call to mount.
    {output, _exitcode} = System.cmd("mount", ["-t", "devfs"], stderr_to_stdout: true)
    output |> String.split("\n") |> Enum.map(&umount_container_devfs(&1, mountpoint))
  end

  defp jexec_container(%Container{
         id: container_id,
         command: cmd,
         user: user,
         env_vars: env_vars
       }) do
    # jexec [-l] [-u username | -U username] jail [command ...]
    args = ~w"-l -u #{user} #{container_id} /usr/bin/env -i" ++ env_vars ++ cmd

    port =
      Port.open(
        {:spawn_executable, '/usr/sbin/jexec'},
        [:stderr_to_stdout, :binary, :exit_status, {:args, args}]
      )

    Logger.debug("Executing /usr/sbin/jexec #{Enum.join(args, " ")}")
    port
  end

  defp jail_start_container(
         %Container{
           id: id,
           layer_id: layer_id,
           command: command,
           user: user,
           parameters: parameters,
           env_vars: env_vars
         } = cont
       ) do
    Logger.info("Starting container #{inspect(cont.id)}")

    network_config =
      case MetaData.connected_networks(id) do
        ["host"] ->
          "ip4=inherit"

        network_ids ->
          ips = Enum.reduce(network_ids, [], &extract_ips(id, &1, &2))
          ips_as_string = Enum.join(ips, ",")
          "ip4.addr=#{ips_as_string}"
      end

    %Layer{mountpoint: path} = Jocker.Engine.MetaData.get_layer(layer_id)

    args =
      ~w"-c path=#{path} name=#{id} #{network_config}" ++
        parameters ++
        ~w"exec.jail_user=#{user} command=/usr/bin/env -i" ++ env_vars ++ command

    Logger.debug("Executing /usr/sbin/jail #{Enum.join(args, " ")}")

    port =
      Port.open(
        {:spawn_executable, '/usr/sbin/jail'},
        [:stderr_to_stdout, :binary, :exit_status, {:args, args}]
      )

    port
  end

  def extract_ips(container_id, network_id, ip_list) do
    config = MetaData.get_endpoint_config(container_id, network_id)
    Enum.concat(config.ip_addresses, ip_list)
  end

  defp relay_msg(msg, state) do
    wrapped_msg = {:container, state.exec_id, msg}
    Enum.map(state.subscribers, fn x -> Process.send(x, wrapped_msg, []) end)
  end

  defp umount_container_devfs(line, mountpoint) do
    devfs_path = Path.join(mountpoint, "dev")

    case String.split(line, " ") do
      ["devfs", "on", ^devfs_path | _rest] ->
        {msg, n} = System.cmd("/sbin/umount", [devfs_path], stderr_to_stdout: true)
        Logger.info("unmounting #{devfs_path} with status code #{n} and msg #{msg}")

      _ ->
        :ok
    end
  end
end
