defmodule Kleened.API.ExecStartWebSocket do
  alias OpenApiSpex.{Operation, Cast}
  alias Kleened.Core.Exec
  alias Kleened.API.{Schemas, Utils}
  require Logger

  import OpenApiSpex.Operation,
    only: [response: 3, request_body: 4]

  defmodule State do
    defstruct handshaking: nil,
              exec_id: nil
  end

  def open_api_operation(_) do
    %Operation{
      # tags: ["users"],
      summary: "exec start",
      description: "make a description of the websocket endpoint here.",
      operationId: "ExecStartWebSocket",
      requestBody:
        request_body(
          "Execution starting configuration.",
          "application/json",
          Schemas.ExecStartConfig,
          required: true
        ),
      responses: %{
        400 => response("invalid parameters", "text/plain", nil)
      }
    }
  end

  # Called on connection initialization
  def init(req0, _opts) do
    {:cowboy_websocket, req0, %State{handshaking: true}, %{idle_timeout: 60000}}
  end

  # Called on websocket connection initialization.
  def websocket_init(state) do
    {[], state}
  end

  def websocket_handle({:text, message_raw}, %{handshaking: true} = state) do
    case Jason.decode(message_raw) do
      {:ok, message} ->
        case Cast.cast(Schemas.ExecStartConfig.schema(), message) do
          {:ok, %{exec_id: exec_id, attach: attach, start_container: start_container}} ->
            result = Exec.start(exec_id, %{attach: attach, start_container: start_container})

            case {result, attach} do
              {:ok, true} ->
                Logger.debug("succesfully started executable #{exec_id}. Await output.")
                {[{:text, Utils.starting_message()}], %State{state | handshaking: false}}

              {:ok, false} ->
                Logger.debug("succesfully started executable #{exec_id}. Closing websocket.")

                closing =
                  Utils.closing_message("succesfully started execution instance in detached mode")

                {[{:close, 1001, closing}], state}

              {:error, reason} ->
                Logger.debug("could not start attached executable #{exec_id}: #{reason}")
                error = Utils.error_message(reason)
                {[{:close, 1011, error}], state}
            end

          {:error, openapispex_error} ->
            error_message = Cast.Error.message(openapispex_error)

            error = Utils.error_message("invalid parameters: #{error_message}")
            {[{:close, 1002, error}], state}
        end

      {:error, json_error} ->
        error = Utils.error_message("invalid json: #{json_error}")
        {[{:close, 1002, error}], state}
    end
  end

  def websocket_handle({:text, message}, %{exec_id: exec_id, handshaking: false} = state) do
    Exec.send(exec_id, message)
    {:ok, state}
  end

  def websocket_handle({:ping, _}, state) do
    {:ok, state}
  end

  def websocket_handle(msg, state) do
    # Ignore unknown messages
    Logger.warn("unknown message received: #{inspect(msg)}")
    {:ok, state}
  end

  def websocket_info({:container, exec_id, {:shutdown, {:jail_stopped, exit_code}}}, state) do
    msg =
      Utils.closing_message(
        "executable #{exec_id} and its container exited with exit-code #{exit_code}"
      )

    {[{:close, 1000, msg}], state}
  end

  def websocket_info(
        {:container, exec_id, {:shutdown, {:jailed_process_exited, exit_code}}},
        state
      ) do
    msg = Utils.closing_message("#{exec_id} has exited with exit-code #{exit_code}")
    {[{:close, 1000, msg}], state}
  end

  def websocket_info({:container, _container_id, {:jail_output, msg}}, state) do
    {[{:text, msg}], state}
  end

  def websocket_info(message, state) do
    Logger.warn("unknown message received: #{inspect(message)}")
    {:ok, state}
  end

  def terminate(reason, _partial_req, %{exec_id: exec_id, attach: attach}) do
    Logger.debug("connection closed #{inspect(reason)}")

    case attach do
      true ->
        Logger.debug("stopping container since it is an attached websocket")
        Exec.stop(exec_id, %{force_stop: false, stop_container: false})

      false ->
        :ok
    end
  end

  def terminate(reason, _partial_req, _state) do
    Logger.debug("connection closed #{inspect(reason)}")
    :ok
  end
end
