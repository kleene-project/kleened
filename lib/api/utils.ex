defmodule Jocker.API.Utils do
  def error_response(msg) do
    Jason.encode!(%{message: msg})
  end

  def id_response(id) do
    Jason.encode!(%{id: id})
  end
end
