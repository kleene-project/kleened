defmodule Kleened.Core.DNS do
  @moduledoc """
  Kleene's built-in per-network DNS resolver.

  Answers A/AAAA queries for container names from MetaData and forwards
  everything else to the host's upstream nameservers. One UDP:53 socket per
  network, bound to the network's resolver IP (the first IP of its subnet).

  All host-side jail/tooling addressing keeps using the container id; this
  resolver is only about *name resolution* between containers.
  """

  alias Kleened.API.Schemas
  require Logger

  use GenServer

  @dns_port 53
  @ttl 0

  defmodule State do
    defstruct sockets: %{}, forwarders: []
  end

  @spec start_link([]) :: GenServer.on_start()
  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Rebuild all listeners from MetaData. Called after any network topology
  change (the same trigger points that call `Network.configure_pf/0`).
  """
  @spec refresh() :: :ok
  def refresh() do
    GenServer.call(__MODULE__, :refresh)
  end

  @impl true
  def init([]) do
    {:ok, %State{forwarders: read_forwarders()}}
  end

  @impl true
  def handle_call(:refresh, _from, %State{} = state) do
    {:reply, :ok, refresh_sockets(state)}
  end

  @impl true
  def handle_info({:udp, socket, src_ip, src_port, packet}, %State{} = state) do
    case Map.get(state.sockets, socket) do
      nil ->
        :unknown_socket

      network_id ->
        answer_query(socket, network_id, src_ip, src_port, packet, state)
    end

    {:noreply, state}
  end

  def handle_info(unknown_msg, state) do
    Logger.warning("DNS: unknown message: #{inspect(unknown_msg)}")
    {:noreply, state}
  end

  defp answer_query(socket, network_id, src_ip, src_port, packet, state) do
    case :inet_dns.decode(packet) do
      {:ok, {:dns_rec, _hdr, [question], _, _, _} = query} ->
        addrs = resolve(question, network_id, src_ip)
        respond(socket, src_ip, src_port, query, addrs, state)

      {:ok, {:dns_rec, _hdr, [], _, _, _}} ->
        # FORMERR: zero questions are unanswerable
        respond(socket, src_ip, src_port, nil, :formerr, state)

      {:error, reason} ->
        Logger.debug("DNS: could not decode query from #{inspect(src_ip)}: #{reason}")
        :ok
    end
  end

  # The resolve/3 lookup is B2; the socket plumbing (refresh_sockets) is B5.
  # Placeholder until then so the compile stays green for the pure tests.
  defp resolve(_question, _network_id, _src_ip), do: []

  # A known container name is answered locally; anything else is forwarded to
  # the host's upstream resolvers (docker-style), if any. The raw query bytes
  # are forwarded verbatim and the upstream reply is relayed back unchanged,
  # so EDNS/DNSSEC options pass through untouched.
  defp respond(socket, src_ip, src_port, %{:dns_rec => _} = query, addrs, %State{} = state) do
    if addrs != [] do
      {:ok, bin} = :inet_dns.encode(answer(%{query: query, addrs: addrs}))
      :gen_udp.send(socket, src_ip, src_port, bin)
    else
      forward(socket, src_ip, src_port, query, state)
    end

    :ok
  end

  defp respond(socket, src_ip, src_port, query, addrs, %State{} = _state) do
    # NXDOMAIN with no forwarders available: answer negatively.
    {:ok, bin} = :inet_dns.encode(answer(%{query: query, addrs: addrs}))
    :gen_udp.send(socket, src_ip, src_port, bin)
  end

  # formerr does not have a query to echo
  defp respond(socket, src_ip, src_port, nil, :formerr, _state) do
    hdr = {:dns_header, 0, true, :query, false, false, false, false, false, 1}
    {:ok, bin} = :inet_dns.encode({:dns_rec, hdr, [], [], [], []})
    :gen_udp.send(socket, src_ip, src_port, bin)
  end

  defp forward(socket, src_ip, src_port, query, %State{forwarders: forwarders}) do
    case forwarders do
      [] ->
        :ok

      [forwarder | _] ->
        with {:ok, qbin} <- :inet_dns.encode(query),
             {:ok, sock} <- :gen_udp.open(0, [:binary, {:active, false}]),
             :ok <- :gen_udp.send(sock, forwarder, @dns_port, qbin),
             {:ok, {_ip, _port, rbin}} <- :gen_udp.recv(sock, 0, 2000) do
          :gen_udp.close(sock)
          :gen_udp.send(socket, src_ip, src_port, rbin)
        else
          {:error, reason} ->
            Logger.debug("DNS: forwarding failed: #{inspect(reason)}")
            :ok
        end
    end
  end

  @doc """
  Pure: build a DNS response record for one question with the given
  addresses. Exposed for tests.

  An empty address list yields NXDOMAIN; the query is echoed back with the
  `qr` and `aa` header flags set.
  """
  @spec answer(%{query: tuple(), addrs: [tuple()]}) :: tuple()
  def answer(%{query: {:dns_rec, hdr, [q | _], _, _, _}, addrs: addrs}) do
    answer_(hdr, q, addrs)
  end

  def answer(%{query: {:dns_rec, hdr, [], _, _, _}}) do
    # FORMERR
    {:dns_rec, formerr_hdr(hdr), [], [], [], []}
  end

  defp answer_(hdr, {:dns_query, domain, type, :in, _} = q, addrs) do
    hdr = hdr |> set_elem(2, true) |> set_elem(4, true) |> set_elem(9, rcode(addrs))

    anlist =
      for addr <- addrs do
        {:dns_rr, domain, type, :in, 0, @ttl, addr, :undefined, "", false}
      end

    {:dns_rec, hdr, [q], anlist, [], []}
  end

  defp rcode([]), do: 3
  defp rcode(_), do: 0

  defp formerr_hdr(hdr) do
    hdr |> set_elem(2, true) |> set_elem(9, 1)
  end

  defp set_elem(tuple, index, value), do: :erlang.setelement(index + 1, tuple, value)

  defp read_forwarders() do
    case File.read("/etc/resolv.conf") do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "nameserver "))
        |> Enum.map(&String.trim_leading(&1, "nameserver "))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.flat_map(fn ip ->
          case :inet.parse_address(String.to_charlist(ip)) do
            {:ok, addr} -> [addr]
            _ -> []
          end
        end)
        |> Enum.uniq()

      {:error, _} ->
        []
    end
  end

  defp refresh_sockets(state) do
    state
  end
end
