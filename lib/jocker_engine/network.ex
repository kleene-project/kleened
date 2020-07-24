defmodule Jocker.Engine.Network do
  use GenServer
  alias Jocker.Engine.Config
  require Logger
  require Record

  Record.defrecordp(:state,
    first: :none,
    last: :none,
    in_use: :none,
    if_name: :none
  )

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def new(), do: GenServer.call(__MODULE__, :new)

  def remove(ip), do: GenServer.call(__MODULE__, {:remove, ip})

  def add_to_if(:out_of_ips, _iface) do
    :error
  end

  def add_to_if(ip, iface) do
    case System.cmd("ifconfig", [iface, "alias", "#{ip}/32"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {error, _} ->
        Logger.error("Some error occured while adding #{ip} to #{iface}: #{error}")
        :error
    end
  end

  def ip_added?(ip) do
    if_name = Config.get(:network_if_name)

    {output, n} =
      System.cmd("/bin/sh", ["-c", "ifconfig #{if_name} | grep \"inet \" | grep \"#{ip}\""],
        stderr_to_stdout: true
      )

    expected_output = "\tinet #{ip} netmask 0xffffffff\n"

    {expected_output, 0} == {output, n}
  end

  ### Callback functions

  @impl true
  def init([]) do
    # Internally we convert ip-addresses to integers so they can be easily manipulated
    case CIDR.parse(Config.get(:subnet)) do
      %CIDR{first: ip_start, last: ip_end, hosts: _nhosts, mask: _mask} ->
        ip_first = Enum.join(Tuple.to_list(ip_start), ".")
        ip_end = Enum.join(Tuple.to_list(ip_end), ".")
        if_name = Config.get(:network_if_name)
        create_network_interface(if_name)

        state =
          state(
            first: ip2int(ip_first),
            last: ip2int(ip_end),
            in_use: MapSet.new(),
            if_name: if_name
          )

        {:ok, state}

      {:error, reason} ->
        Logger.error("Unable to parse 'network_if_name' in configuration file.")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:new, _from, state(first: first, if_name: if_name) = state) do
    {new_ip, in_use} = new_ip(first, state)
    add_to_if(new_ip, if_name)
    {:reply, new_ip, state(state, in_use: in_use)}
  end

  def handle_call({:remove, ip}, _from, state(if_name: if_name) = state) do
    remove_from_if(ip, if_name)
    new_in_use = remove_ip(ip, state)
    {:reply, :ok, state(state, in_use: new_in_use)}
  end

  @impl true
  def terminate(_reason, state(if_name: if_name)) do
    System.cmd("ifconfig", [if_name, "destroy"])
    :ok
  end

  ### Internal functions
  defp create_network_interface(jocker_if) do
    if interface_exists(jocker_if) do
      {"", _exitcode} = System.cmd("ifconfig", [jocker_if, "destroy"])
    end

    _jocker_if_out = jocker_if <> "\n"
    {_jocker_if_out, 0} = System.cmd("ifconfig", ["lo", "create", "name", jocker_if])
  end

  defp interface_exists(jocker_if) do
    {if_list, 0} = System.cmd("ifconfig", ["-l"])
    if_list |> String.trim() |> String.split() |> Enum.find_value(fn x -> x == jocker_if end)
  end

  defp remove_from_if(ip, iface) do
    case System.cmd("ifconfig", [iface, "-alias", "#{ip}"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {error, _} -> Logger.warn("Some error occured while removing #{ip} from #{iface}: #{error}")
    end
  end

  defp remove_ip(ip, state(in_use: in_use)) do
    ip_int = ip2int(ip)
    MapSet.delete(in_use, ip_int)
  end

  defp new_ip(next, state(last: last, in_use: ips)) when next > last do
    {:out_of_ips, ips}
  end

  defp new_ip(next, state(in_use: in_use) = state) do
    case MapSet.member?(in_use, next) do
      true ->
        new_ip(next + 1, state)

      false ->
        new_ip = int2ip(next)
        {new_ip, MapSet.put(in_use, next)}
    end
  end

  defp int2ip(n) do
    int2ip_(n, 3, [])
  end

  defp int2ip_(n, 0, prev) do
    [n | prev]
    |> Enum.reverse()
    |> List.to_tuple()
    |> :inet.ntoa()
    |> to_string()
  end

  defp int2ip_(n, order, prev) do
    x = floor(n / pow(order))
    n_next = n - x * pow(order)
    int2ip_(n_next, order - 1, [x | prev])
  end

  defp ip2int(ip) do
    {:ok, {a, b, c, d}} = ip |> to_charlist() |> :inet.parse_address()
    d + c * pow(1) + b * pow(2) + a * pow(3)
  end

  defp pow(n) do
    :erlang.round(:math.pow(256, n))
  end
end
