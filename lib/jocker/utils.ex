defmodule Jocker.Utils do
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
end
