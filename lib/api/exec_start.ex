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
      description: """
      #{Utils.general_websocket_description()}

      * The starting-message does not have any content.
      * If the exec-instance is started with `attach: false` the starting-message is followed by a
        Close frame with Close Code 1001.
      * When the executed process exits the closing-message in the Close frame tells wether the
        entire container has been stopped or just the exec-instance.
      """,
      operationId: "ExecStartWebSocket",
      requestBody:
        request_body(
          "Execution starting configuration.",
          "application/json",
          Schemas.ExecStartConfig,
          required: true
        ),
      responses: %{
        200 => response("no error", "application/json", Schemas.WebSocketMessage)
      }
    }
  end

  # Called on connection initialization
  def init(req0, _opts) do
    {:cowboy_websocket, req0, %State{handshaking: true}, %{idle_timeout: 60_000}}
  end

  # Called on websocket connection initialization.
  def websocket_init(state) do
    {[], state}
  end

  def websocket_handle({:text, message_raw}, %{handshaking: true} = state) do
    case Jason.decode(message_raw, keys: :atoms!) do
      {:ok, message} ->
        case Cast.cast(Schemas.ExecStartConfig.schema(), message) do
          {:ok, %{exec_id: exec_id, attach: attach, start_container: start_container}} ->
            result = Exec.start(exec_id, %{attach: attach, start_container: start_container})

            case {result, attach} do
              {:ok, true} ->
                Logger.debug("succesfully started executable #{exec_id}. Await output.")
                state = %State{state | handshaking: false, exec_id: exec_id}
                {[{:text, Utils.starting_message()}], state}

              {:ok, false} ->
                Logger.debug("succesfully started executable #{exec_id}. Closing websocket.")
                msg = "succesfully started execution instance in detached mode"
                {[{:close, 1001, Utils.closing_message(msg)}], state}

              {{:error, reason}, _} ->
                Logger.debug("could not start attached executable #{exec_id}: #{reason}")
                error = Utils.error_message("error starting exec instance")

                {[
                   {:text, "error: #{reason}"},
                   {:close, 1011, error}
                 ], state}
            end

          {:error, [openapispex_error | _rest]} ->
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
    :ok = Exec.send(exec_id, message)
    {:ok, state}
  end

  def websocket_handle({:binary, message}, %{exec_id: exec_id, handshaking: false} = state) do
    :ok = Exec.send(exec_id, message)
    {:ok, state}
  end

  def websocket_handle({:ping, _}, state) do
    {:ok, state}
  end

  def websocket_handle(msg, state) do
    # Ignore unknown messages
    Logger.warning("unknown message received: #{inspect(msg)}")
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
    Logger.warning("unknown message received: #{inspect(message)}")
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
