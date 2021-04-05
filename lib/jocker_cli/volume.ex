defmodule Jocker.CLI.Volume do
  alias Jocker.CLI.Utils
  alias Jocker.Engine.Volume
  import Utils, only: [cell: 2, sp: 1, to_cli: 1, to_cli: 2, rpc: 1]

  @doc """

  Usage:	jocker volume COMMAND

  Manage volumes

  Commands:
    create      Create a volume
    ls          List volumes
    rm          Remove one or more volumes

  Run 'jocker volume COMMAND --help' for more information on a command.
  """
  def main_docs(), do: @doc

  @doc """

  Usage:	jocker volume create [VOLUME NAME]

  Create a new volume. If no volume name is provided jocker generates one.
  If the volume name already exists nothing happens.
  """
  def create(:spec) do
    [
      name: "volume create",
      docs: @doc,
      arg_spec: "==0 or ==1",
      arg_options: [help: :boolean]
    ]
  end

  def create({_options, args}) do
    %Volume{name: name} = rpc([Volume, :create_volume, args])
    to_cli(name <> "\n", :eof)
  end

  @doc """

  Usage:  jocker volume rm VOLUME [VOLUME ...]

  Remove one or more volumes
  """
  def rm(:spec) do
    [
      name: "volume rm",
      docs: @doc,
      arg_spec: "=>1",
      arg_options: [help: :boolean]
    ]
  end

  def rm({_options, volumes}) do
    Enum.map(volumes, &remove_a_volume/1)
    to_cli(nil, :eof)
  end

  @doc """

  Usage:	jocker volume ls [OPTIONS]

  List volumes

  Options:
    -q, --quiet           Only display volume names
  """
  def ls(:spec) do
    [
      name: "volume ls",
      docs: @doc,
      arg_spec: "==0",
      aliases: [q: :quiet],
      arg_options: [
        quiet: :boolean,
        help: :boolean
      ]
    ]
  end

  def ls({options, []}) do
    volumes = rpc([Jocker.Engine.MetaData, :list_volumes, []])

    case Keyword.get(options, :quiet, false) do
      false ->
        print_volume(["VOLUME NAME", "CREATED"])

        Enum.map(volumes, fn %Volume{name: name, created: created} ->
          print_volume([name, created])
        end)

      true ->
        Enum.map(volumes, fn %Volume{name: name} -> to_cli("#{name}\n") end)
    end

    to_cli(nil, :eof)
  end

  defp remove_a_volume(name) do
    case rpc([Jocker.Engine.MetaData, :get_volume, [name]]) do
      :not_found ->
        to_cli("Error: No such volume: #{name}\n")

      volume ->
        :ok = rpc([Jocker.Engine.Volume, :destroy_volume, [volume]])
        to_cli("#{name}\n")
    end
  end

  defp print_volume([name, created]) do
    name = cell(name, 14)
    timestamp = Utils.format_timestamp(created)
    n = 3
    to_cli("#{name}#{sp(n)}#{timestamp}\n")
  end
end
