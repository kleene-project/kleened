defmodule Kleened.Core.OS do
  require Logger

  @spec cmd([String.t()], %{}) :: {String.t(), integer()}
  def cmd([executable | args] = command, options \\ %{suppress_warning: false}) do
    {stdout, exit_code} = return_value = System.cmd(executable, args, stderr_to_stdout: true)

    case {exit_code, options} do
      {_, %{suppress_warning: false}} when exit_code != 0 ->
        Logger.warning(
          "'#{Enum.join(command, " ")}' executed with exit-code #{exit_code}: \"#{
            String.trim(stdout)
          }\""
        )

      _ ->
        Logger.debug(
          "'#{Enum.join(command, " ")}' executed with exit-code #{exit_code}: \"#{
            String.trim(stdout)
          }\""
        )
    end

    return_value
  end

  def cmd_async(command, use_pty \\ false) do
    {executable, args} =
      case use_pty do
        false ->
          [executable | args] = command
          {executable, args}

        true ->
          case Application.get_env(:kleened, :env) do
            :prod -> {"/usr/local/bin/kleened_pty", command}
            _ -> {"priv/bin/kleened_pty", command}
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
