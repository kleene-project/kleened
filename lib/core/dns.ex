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
  alias Kleened.Core.{FreeBSD, MetaData, ZFS}
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

  @doc "The internal state, for tests and diagnostics."
  @spec inspect_state() :: {:ok, term()}
  def inspect_state() do
    GenServer.call(__MODULE__, :inspect)
  end

  @doc """
  Write the container's /etc/resolv.conf and the kleene-managed block of its
  /etc/hosts, pointing at the resolvers of the container's networks. Called
  from Exec.jail_start_container before the jail is created.

  `host`/`disabled`-driver containers have no network interface of their
  own and keep their files untouched.
  """
  @spec configure_dns_files(Schemas.Container.t()) :: :ok
  def configure_dns_files(%Schemas.Container{network_driver: driver})
      when driver in ["host", "disabled"],
      do: :ok

  def configure_dns_files(%Schemas.Container{} = container) do
    networks = MetaData.connected_networks(container.id)

    mountpoint = ZFS.mountpoint(container.dataset)
    write_resolv_conf(mountpoint, container, networks)
    write_hosts_block(mountpoint, container, networks)
    :ok
  end

  defp write_resolv_conf(mountpoint, _container, networks) do
    entries =
      networks
      |> Enum.flat_map(fn network ->
        case resolver_ip(network) do
          nil -> []
          ip -> ["nameserver #{:inet.ntoa(ip)}", "search #{network.name}"]
        end
      end)

    # Networks without resolvers leave the image's resolv.conf in place.
    case entries do
      [] -> :ok
      _ -> File.write(Path.join(mountpoint, "etc/resolv.conf"), Enum.join(entries, "\n") <> "\n")
    end
  end

  @hosts_start "# kleene-managed hosts start"
  @hosts_end "# kleene-managed hosts end"

  defp write_hosts_block(mountpoint, container, networks) do
    path = Path.join(mountpoint, "etc/hosts")

    existing =
      case File.read(path) do
        {:ok, content} -> String.replace_suffix(content, "\n", "")
        {:error, _} -> "127.0.0.1 localhost\n::1 localhost"
      end

    # Drop any previous kleene-managed block, then append the fresh one.
    kept =
      existing
      |> String.split(@hosts_start)
      |> hd()
      |> String.trim_trailing()
      |> String.trim_trailing(@hosts_end)
      |> String.trim_trailing()

    own_entries =
      networks
      |> Enum.flat_map(fn network ->
        endpoint = MetaData.get_endpoint(container.id, network.id)

        case endpoint do
          %Schemas.EndPoint{} = ep ->
            [{ep.ip_address, container.name}, {ep.ip_address6, container.name}]

          :not_found ->
            []
        end
      end)
      |> Enum.reject(fn {ip, _name} -> ip in [nil, ""] end)
      |> Enum.map(fn {ip, name} -> "#{ip}  #{name}" end)
      |> Enum.join("\n")

    block = Enum.join([@hosts_start, own_entries, @hosts_end], "\n")
    File.write(path, kept <> "\n\n" <> block <> "\n")
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
  def handle_call(:inspect, _from, state) do
    {:reply, {:ok, state}, state}
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

  # B2: a query arriving on network `network_id` from `src_ip` resolves the
  # queried name against container names. The answer carries the target
  # container's address on that network: the question's own network scope is
  # the network the query arrived on, so a container reachable on it is
  # answered with that address (docker-style per-network isolation).
  defp resolve({:dns_query, domain, type, :in, _}, network_id, _src_ip) do
    name = domain |> to_string() |> String.downcase()

    endpoints =
      case MetaData.get_container_by_name(name) do
        %Schemas.Container{id: target_id} ->
          MetaData.get_endpoints_from_container(target_id)

        :not_found ->
          []
      end

    endpoints
    |> Enum.filter(&(&1.network_id == network_id))
    |> Enum.flat_map(fn %Schemas.EndPoint{ip_address: ip, ip_address6: ip6} = ep ->
      case type do
        :a -> parse_ips([ip])
        :aaaa -> parse_ips([ip6])
        _ -> parse_ips([ip, ep.ip_address6])
      end
    end)
  end

  defp parse_ips(ips) do
    ips
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.flat_map(fn ip ->
      case :inet.parse_address(String.to_charlist(ip)) do
        {:ok, addr} -> [addr]
        _ -> []
      end
    end)
  end

  # A known container name is answered locally; anything else is forwarded to
  # the host's upstream resolvers (docker-style), if any. The raw query bytes
  # are forwarded verbatim and the upstream reply is relayed back unchanged,
  # so EDNS/DNSSEC options pass through untouched. When forwarding is not
  # possible (no forwarders, or the upstream cannot answer), the query is
  # answered negatively instead.
  defp respond(socket, src_ip, src_port, nil, :formerr, _state) do
    hdr = {:dns_header, 0, true, :query, false, false, false, false, false, 1}
    bin = :inet_dns.encode({:dns_rec, hdr, [], [], [], []})
    :gen_udp.send(socket, src_ip, src_port, bin)
  end

  defp respond(socket, src_ip, src_port, {:dns_rec, _, _, _, _, _} = query, addrs, %State{} = state) do
    if addrs != [] do
      bin = :inet_dns.encode(answer(%{query: query, addrs: addrs}))
      :gen_udp.send(socket, src_ip, src_port, bin)
    else
      case forward(socket, src_ip, src_port, query, state) do
        :forwarded -> :ok
        :not_forwarded -> send_nxdomain(socket, src_ip, src_port, query)
      end
    end

    :ok
  end

  defp send_nxdomain(socket, src_ip, src_port, query) do
    bin = :inet_dns.encode(answer(%{query: query, addrs: []}))
    :gen_udp.send(socket, src_ip, src_port, bin)
  end

  defp forward(socket, src_ip, src_port, query, %State{forwarders: forwarders}) do
    case forwarders do
      [] ->
        :not_forwarded

      [forwarder | _rest] ->
        qbin = :inet_dns.encode(query)

        with {:ok, sock} <- :gen_udp.open(0, [:binary, {:active, false}]),
             :ok <- :gen_udp.send(sock, forwarder, @dns_port, qbin),
             {:ok, {_ip, _port, rbin}} <- :gen_udp.recv(sock, 0, 2000) do
          :gen_udp.close(sock)
          :gen_udp.send(socket, src_ip, src_port, rbin)
          :forwarded
        else
          {:error, reason} ->
            Logger.debug("DNS: forwarding failed: #{inspect(reason)}")
            :not_forwarded
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

  # One UDP:53 socket per network, bound to the network's resolver IP: the
  # first usable address of its subnet (the same IP the '<auto>' gateway
  # alias uses, so the alias usually already exists on the interface). The
  # alias is ensured before binding: on networks without a gateway, DNS owns
  # the only first-IP alias. A bind failure (e.g. another service on port 53
  # of that IP) disables DNS for that network, like a pf load failure
  # disables the ruleset.
  defp refresh_sockets(%State{} = state) do
    networks = MetaData.list_networks()

    wanted =
      networks
      |> Enum.flat_map(fn network ->
        case resolver_ip(network) do
          nil -> []
          ip -> [{network.id, ip, network}]
        end
      end)
      |> Map.new(fn {id, ip, net} -> {id, {ip, net}} end)

    # Close (and drop) sockets for networks that no longer resolve; keeping
    # the closed port in the map would make later refreshes treat the
    # network as still served.
    {keep, drop} =
      Enum.split_with(state.sockets, fn {_socket, network_id} ->
        Map.has_key?(wanted, network_id)
      end)

    Enum.each(drop, fn {socket, _network_id} -> :gen_udp.close(socket) end)
    sockets = Map.new(keep)

    sockets =
      Enum.reduce(wanted, sockets, fn {network_id, {ip, network}}, sockets ->
        already_open =
          Enum.any?(sockets, fn {_socket, open_id} -> open_id == network_id end)

        case already_open do
          true ->
            sockets

          false ->
            with :ok <- ensure_ip_alias(ip, network) do
              open_socket(network_id, ip, sockets)
            else
              {:error, reason} ->
                Logger.warning(
                  "could not configure DNS resolver address for network #{network_id}: #{inspect(reason)}"
                )

                sockets
            end
        end
      end)

    %State{state | sockets: sockets}
  end

  defp open_socket(network_id, ip, sockets) do
    case :gen_udp.open(@dns_port, [:binary, {:active, true}, {:ip, ip}]) do
      {:ok, socket} ->
        Map.put(sockets, socket, network_id)

      {:error, reason} ->
        Logger.warning(
          "could not bind DNS resolver for network #{network_id} on #{inspect(ip)}: #{inspect(reason)}"
        )

        sockets
    end
  end

  # Add resolver ip alias to the network interface, if it is not already
  # created for the gateway
  defp ensure_ip_alias(ip, %Schemas.Network{interface: interface}) do
    if ip_on_interface?(ip, interface) do
      :ok
    else
      case :inet.ntoa(ip) do
        {:error, reason} ->
          {:error, "could not format resolver IP #{inspect(ip)}: #{inspect(reason)}"}

        ip_string ->
          ip_string = to_string(ip_string)

          case FreeBSD.ifconfig_alias(ip_string, interface, "inet") do
            :ok -> :ok
            {:error, output} -> if String.contains?(output, "File exists"), do: :ok, else: {:error, output}
          end
      end
    end
  end

  defp ip_on_interface?(ip, interface) do
    addresses = FreeBSD.get_interface_addresses(interface)

    Enum.any?(addresses, fn %{"address" => address} ->
      case :inet.parse_address(String.to_charlist(address)) do
        {:ok, ^ip} -> true
        _ -> false
      end
    end)
  end

  # Resolver IP: the first usable IPv4 address of its subnet. Only loopback/bridge networks
  # get a resolver: a custom interface should be managed by the operator.
  # Networks with no subnet or resolver disabled get none either.
  defp resolver_ip(%Schemas.Network{dns: false}), do: nil
  defp resolver_ip(%Schemas.Network{type: "custom"}), do: nil
  defp resolver_ip(%Schemas.Network{subnet: ""}), do: nil

  defp resolver_ip(%Schemas.Network{subnet: subnet}) do
    ip_string = Kleened.Core.Network.first_ip_address(subnet, "inet")

    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end
end
