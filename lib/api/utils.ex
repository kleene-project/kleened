defmodule Kleened.API.Utils do
  alias Kleened.API.Schemas.WebSocketMessage, as: Message
  # Remember that control-frames, such as Close frames must not exceed 125 bytes

  def error_response(msg) do
    Jason.encode!(%{message: msg})
  end

  def id_response(id) do
    Jason.encode!(%{id: id})
  end

  def closing_message(msg, data \\ "") do
    closing_msg =
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

  def error_message(msg) do
    Jason.encode!(%Message{
      msg_type: "error",
      message: msg
    })
  end
end
