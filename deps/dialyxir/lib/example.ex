defmodule Example do
  @spec to_string(atom, encoding) :: binary() when atom: atom(), encoding: :latin1 | :utf8
  def to_string(atom, encoding) do
    :erlang.atom_to_binary(atom, encoding)
  end

  def bad_func do
    __MODULE__.to_string("not a string", :utf8)
  end
end
