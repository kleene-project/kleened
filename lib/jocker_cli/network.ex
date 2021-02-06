defmodule Jocker.CLI.Network do
  alias Jocker.CLI.Utils
  alias Jocker.Structs
  import Utils, only: [cell: 2, sp: 1, to_cli: 1, to_cli: 2, rpc: 1]
  require Logger

  @doc """

  Usage:	jocker network COMMAND

  Manage networks

  Commands:
    create      Create a network
    connect     Connect a container to a network
    disconnect  Disconnect a container from a network
    ls          List networks
    rm          Remove one or more networks

  Run 'jocker network COMMAND --help' for more information on a command.
  """
  def main_docs(), do: @doc

  @doc """

  Usage:  jocker network ls [OPTIONS]

  List networks
  """
  def ls(:spec) do
    [
      name: "network ls",
      docs: @doc,
      arg_spec: "==0",
      arg_options: [
        help: :boolean
      ]
    ]
  end

  def ls({[], []}) do
    header = %{
      id: "NETWORK ID",
      name: "NAME",
      driver: "DRIVER"
    }

    print_network(header)
    networks_raw = rpc([Jocker.Engine.Network, :list, []])

    networks =
      Enum.map(networks_raw, fn %Structs.Network{id: id, name: name} ->
        driver =
          case id do
            "host" -> "host"
            _ -> "loopback"
          end

        %{id: id, name: name, driver: driver}
      end)

    Enum.map(networks, &print_network/1)
    to_cli(nil, :eof)
  end

  @doc """

  Usage:	jocker network create [OPTIONS] NETWORK

  Create a network (only loopback networks are supported atm.)

  Options:
    -d, --driver string        Driver to manage the Network (default "loopback")
        --ifname               Name of the loopback interface
        --subnet string        Subnet in CIDR format that represents the network segment
  """
  def create(:spec) do
    [
      name: "network create",
      docs: @doc,
      arg_spec: "==1",
      aliases: [d: :driver],
      arg_options: [
        driver: :string,
        ifname: :string,
        subnet: :string,
        help: :boolean
      ]
    ]
  end

  def create({options, [name]}) do
    _driver = :loopback
    ifname = Keyword.get(options, :ifname)
    subnet = Keyword.get(options, :subnet)

    cond do
      ifname == nil ->
        to_cli("missing option 'ifname'", :eof)

      subnet == nil ->
        to_cli("missing option 'subnet'", :eof)

      true ->
        case rpc([Jocker.Engine.Network, :create, [name, options]]) do
          {:ok, %Structs.Network{id: id}} ->
            to_cli(id, :eof)

          {:error, reason} ->
            to_cli("error creating network: #{reason}", :eof)
        end
    end
  end

  @doc """

  Usage:	jocker network rm NETWORK [NETWORK...]

  Remove one or more networks

  """
  def rm(:spec) do
    [
      name: "network rm",
      docs: @doc,
      arg_spec: "=>1",
      arg_options: [
        help: :boolean
      ]
    ]
  end

  def rm({_options, containers}) do
    destroy_networks(containers)
    to_cli(nil, :eof)
  end

  defp destroy_networks([network_idname | networks]) do
    case rpc([Jocker.Engine.Network, :remove, [network_idname]]) do
      {:ok, network_id} ->
        to_cli("#{network_id}\n")

      {:error, reason} ->
        to_cli("error with #{network_idname}: #{reason}\n")
    end

    destroy_networks(networks)
  end

  defp destroy_networks([]) do
    :ok
  end

  @doc """

  Usage:	jocker network connect NETWORK CONTAINER

  Connect a container to a network
  """
  def connect(:spec) do
    [
      name: "network connect",
      docs: @doc,
      arg_spec: "==2",
      arg_options: [
        help: :boolean
      ]
    ]
  end

  def connect({[], [network_idname, container_idname]}) do
    case(rpc([Jocker.Engine.Network, :connect, [container_idname, network_idname]])) do
      :ok -> to_cli(:eof)
      {:error, reason} -> to_cli("error: #{reason}", :eof)
    end
  end

  @doc """

  Usage:	docker network disconnect NETWORK CONTAINER

  Disconnect a container from a network
  """
  def disconnect(:spec) do
    [
      name: "network disconnect",
      docs: @doc,
      arg_spec: "==2",
      arg_options: [
        help: :boolean
      ]
    ]
  end

  def disconnect({[], [network_idname, container_idname]}) do
    case(rpc([Jocker.Engine.Network, :disconnect, [container_idname, network_idname]])) do
      :ok -> to_cli(:eof)
      {:error, reason} -> to_cli("error: #{reason}", :eof)
    end
  end

  defp print_network(%{id: id, name: name, driver: driver}) do
    line = [
      cell(id, 12),
      cell(name, 25),
      driver
    ]

    to_cli(Enum.join(line, sp(3)) <> "\n")
  end
end
