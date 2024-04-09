defmodule Kleened.API.Utils do
  alias Kleened.API.Schemas.WebSocketMessage, as: Message
  # Remember that control-frames, such as Close frames must not exceed 125 bytes

  def error_response(msg) do
    Jason.encode!(%{message: msg})
  end

  def id_response(id) do
    Jason.encode!(%{id: id})
  end

  def idlist_response(ids) do
    Jason.encode!(ids)
  end

  def closing_message(msg, data \\ "") do
    Jason.encode!(%Message{
      msg_type: "closing",
      message: msg,
      data: data
    })
  end

  def starting_message(data \\ "") do
    Jason.encode!(%Message{
      msg_type: "starting",
      message: "",
      data: data
    })
  end

  def error_message(msg, data \\ "") do
    Jason.encode!(%Message{
      msg_type: "error",
      message: msg,
      data: data
    })
  end

  def general_websocket_description() do
    """
    > **Important**: This is a 'dummy' specification since the actual endpoint is websocket-based.
    > Below is a description of the websocket protocol and how it relates to the dummy spec.

    ## General websocket protocol used by Kleened
    All of Kleened's websocket endpoints follows a similar pattern, having only differences
    in the contents of the fields in the protocol frames.
    The specifics of the particular endpoint is described below the generic description of the
    protocol.

    Once the websocket is established, Kleened expects a configuration-frame, which is given by
    the specified request body schema. Thus, the contents of request body should be sent as the
    initial websocket frame instead of being contained in initiating request.

    When the config is received, Kleened sends a 'starting-message' back to the client, indicating
    that Kleened has begun processing the request.
    The starting message, like all protocol messages, follows the schema shown for
    the 200-response below (the WebSocketMessage schema) and has `msg_type` set to `starting`.
    After the starting-message, subsequent frames will be 'raw' output from the running process.
    When the process is finished, Kleened closes the websocket with a Close Code 1000 and a
    WebSocketMessage contained in the Close frame's Close Reason.
    The `msg_type` is set to `closing` but the contents of the `data` and `message` fields
    depend on the particular endpoint.

    If the initial configuration message schema is invalid, kleened closes the websocket with
    Close Code 1002 and a WebSocketMessage as the Close frame's Close Reason.
    The `msg_type` is set to `error` and the contents of the `data` and `message` fields will
    depend on the specific error.
    This only happens before a starting-message have been sent to the client.

    If Kleened encounters an error during process execution, Kleened closes the websocket with
    Close Code 1011 and a WebSocketMessage as the Close frame's reason. The `msg_type` is set to
    `error` and the contents of the `data` and `message` fields will depend on the specific error.

    If any unexpected errors/crashes occur during the lifetime of the websocket, Kleend closes
    the websocket with Close Code 1011 and an empty reason field.

    ## Endpoint-specific details
    The following specifics pertain to this endpoint:
    """
  end
end
