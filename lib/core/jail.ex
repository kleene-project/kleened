defmodule Kleened.Core.Jail do
  alias Kleened.API.Schemas

  @doc """
  The default `host.hostname` for a container: its name, falling back to the
  container id when the container has no name.

  Unlike a jail name, a hostname may contain `.` (jail(8) reserves dots for
  the child-jail hierarchy), so dotted container names are used as-is.
  """
  @spec default_hostname(Schemas.Container.t()) :: String.t()
  def default_hostname(%Schemas.Container{id: id, name: name}),
    do: default_hostname(id, name)

  @spec default_hostname(String.t(), String.t() | nil) :: String.t()
  def default_hostname(id, name) do
    if is_binary(name) and name != "" do
      name
    else
      id
    end
  end
end
