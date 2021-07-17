defmodule Jocker.Engine.APIServer do
  alias Jocker.Engine.Config
  require Logger

  def start_link([]) do
    Logger.info("jocker-engine: Initating API backend")
    socket_opts = create_socket_options(Config.get("api_socket"))
    lingering = {:linger, {true, 30000}}

    :ranch.start_listener(
      make_ref(),
      :ranch_tcp,
      [lingering | socket_opts],
      Jocker.Engine.APIConnection,
      []
    )
  end

  defp create_socket_options(api_socket) do
    case api_socket do
      {:unix, path, port} ->
        File.rm(path)
        [{:port, port}, {:ip, {:local, path}}]

      {_iptype, address, port} ->
        [{:port, port}, {:ip, address}]
    end
  end
end
