defmodule Kleened.Core.OS do
  require Logger

  @typedoc """
  Options understood by `cmd/2` and, by extension, everything built on top of it.

  * `suppress_warning` - do not log a warning when the command exits non-zero.
  * `suppress_logging` - do not emit the usual debug log entry for the command.
  """
  @type cmd_options() :: %{
          optional(:suppress_warning) => boolean(),
          optional(:suppress_logging) => boolean()
        }

  @typedoc "The `{stdout_and_stderr, exit_code}` pair returned by a synchronous command."
  @type cmd_result() :: {String.t(), integer()}

  @spec cmd([String.t()], cmd_options()) :: cmd_result()
  def cmd(
        [executable | args] = command,
        options \\ %{}
      ) do
    suppress_warning = Map.get(options, :suppress_warning, false)
    suppress_logging = Map.get(options, :suppress_logging, false)
    {stdout, exit_code} = return_value = System.cmd(executable, args, stderr_to_stdout: true)

    if not suppress_warning and exit_code != 0 do
      Logger.warning(
        "'#{Enum.join(command, " ")}' executed with exit-code #{exit_code}: \"#{String.trim(stdout)}\""
      )
    end

    if not suppress_logging do
      Logger.debug(
        "'#{Enum.join(command, " ")}' executed with exit-code #{exit_code}: \"#{String.trim(stdout)}\""
      )
    end

    return_value
  end

  @spec shell(String.t(), cmd_options()) :: cmd_result()
  def shell(command, options \\ %{suppress_warning: false}) do
    cmd(["/bin/sh", "-c", command], options)
  end

  @spec shell!(String.t(), cmd_options()) :: String.t()
  def shell!(command, options \\ %{suppress_warning: false}) do
    {output, 0} = cmd(["/bin/sh", "-c", command], options)
    output
  end

  @spec cmd_async([String.t()], boolean()) :: port()
  def cmd_async(command, use_pty \\ false) do
    {executable, args} =
      case use_pty do
        false ->
          [executable | args] = command
          {executable, args}

        true ->
          # It is assumed that 'kleened_pty' can be found using PATH
          case :os.find_executable(~c"kleened_pty") do
            pty_executable when is_list(pty_executable) ->
              {List.to_string(pty_executable), command}

            _error ->
              Logger.warning("executable kleened_pty not found. Unable to allocate pseudo-TTY.")
          end
      end

    port =
      Port.open(
        {:spawn_executable, executable},
        [:stderr_to_stdout, :binary, :exit_status, {:args, args}]
      )

    Logger.debug("spawned #{inspect(port)} using '#{Enum.join([executable | args], " ")}'")
    port
  end
end
