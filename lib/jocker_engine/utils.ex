defmodule Jocker.Engine.Utils do
  def decode_tagname(tagname) do
    case String.split(tagname, ":") do
      [name] ->
        {name, "latest"}

      [name, tag] ->
        {name, tag}
    end
  end

  def uuid() do
    uuid_all = UUID.uuid4(:hex)
    <<uuid::binary-size(12), _rest::binary>> = uuid_all
    uuid
  end

  def decode_buffer(buffer) do
    case :erlang.binary_to_term(buffer) do
      :badarg ->
        {:no_full_msg, buffer}

      reply ->
        buffer_size = byte_size(:erlang.term_to_binary(buffer))
        used_size = byte_size(:erlang.term_to_binary(reply))
        new_buffer = String.slice(buffer, used_size, buffer_size)
        {reply, new_buffer}
    end
  end
end
