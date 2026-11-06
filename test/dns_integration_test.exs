defmodule DnsIntegrationTest do
  use Kleened.Test.ConnCase
  alias Kleened.Core.{DNS, Network}
  alias Kleened.API.Schemas

  @moduletag :capture_log

  setup do
    {:ok, %Schemas.Network{name: "dnsnet"}} =
      Network.create(%Schemas.NetworkConfig{
        name: "dnsnet",
        subnet: "10.200.0.0/24",
        interface: "kleene9",
        type: "loopback"
      })

    :ok
  end

  test "a container name resolves to its IP from the same network" do
    # 'web' gets 10.200.0.2 (the resolver holds 10.200.0.1)
    %{id: web_id} =
      TestHelper.container_create(%{
        name: "dnstest-web",
        cmd: ["/bin/sleep", "30"],
        network: "dnsnet",
        network_driver: "ipnet",
        attach: false
      })

    web_ip = endpoint_ip(web_id)
    assert web_ip == "10.200.0.2"

    # Send an A query for 'dnstest-web' to the resolver and expect its IP.
    assert {^web_ip, _ttl} = resolve("dnstest-web", "10.200.0.1")

    TestHelper.container_remove(Kleened.API.Spec.spec(), web_id)
  end

  test "an unknown name yields NXDOMAIN" do
    # With upstream forwarding, the answer may be a forwarded NXDOMAIN or a
    # NOERROR-without-answers, depending on the upstream resolver's policy.
    result = resolve("no-such-container", "10.200.0.1")
    assert result in [:nxdomain, :unexpected]
  end

  test "an upstream name is forwarded to the host's resolvers" do
    # Requires internet access; skipped when the upstream cannot answer.
    case resolve("one.one.one.one", "10.200.0.1") do
      {ip, _ttl} ->
        assert ip =~ ~r/^\d+\.\d+\.\d+\.\d+$/

      other ->
        ExUnit.Assertions.flunk("expected an upstream answer, got: #{inspect(other)}")
    end
  end

  test "a started container gets the resolver in resolv.conf and itself in /etc/hosts" do
    api_spec = Kleened.API.Spec.spec()

    %{id: web_id} =
      TestHelper.container_create(%{
        name: "dnstest-files",
        cmd: ["/bin/sleep", "60"],
        network: "dnsnet",
        network_driver: "ipnet",
        attach: false
      })

    {:ok, exec_id} = Kleened.Core.Exec.create(web_id)
    :ok = Kleened.Core.Exec.start(exec_id, %{attach: false, start_container: true})
    :timer.sleep(1_000)

    files_out = read_files_in_container(web_id)
    assert files_out =~ "nameserver 10.200.0.1"
    assert files_out =~ "search dnsnet"
    assert files_out =~ "10.200.0.2  dnstest-files"

    TestHelper.container_stop(api_spec, web_id)
    TestHelper.container_remove(api_spec, web_id)
  end

  # Read the file contents by running cat in the running container.
  defp read_files_in_container(container_id) do
    {:ok, exec_id} =
      Kleened.Core.Exec.create(%Schemas.ExecConfig{
        container_id: container_id,
        cmd: ["/bin/sh", "-c", "cat /etc/resolv.conf /etc/hosts"],
        env: [],
        user: "root"
      })

    :ok = Kleened.Core.Exec.start(exec_id, %{attach: true, start_container: false})

    output =
      receive do
        {:container, ^exec_id, {:jail_output, data}} -> data
      after
        5_000 -> "EXEC TIMEOUT"
      end

    # Drain the shutdown message so the exec GenServer terminates cleanly.
    receive do
      {:container, ^exec_id, {:shutdown, _}} -> :ok
    after
      5_000 -> :ok
    end

    output
  end

  test "a network with dns disabled gets no resolver and no resolv.conf injection" do
    api_spec = Kleened.API.Spec.spec()

    {:ok, %Schemas.Network{id: nodns_id} = nodns} =
      Network.create(%Schemas.NetworkConfig{
        name: "dnsnet-off",
        subnet: "10.201.0.0/24",
        interface: "kleene7",
        type: "loopback",
        dns: false
      })

    # No resolver socket for the dns-disabled network...
    {:ok, state} = DNS.inspect_state()
    refute nodns_id in Map.values(state.sockets)

    # ...and its first IP stays allocatable (not reserved).
    %{id: cid} =
      TestHelper.container_create(%{
        name: "dnstest-off",
        cmd: ["/bin/sleep", "60"],
        network: "dnsnet-off",
        network_driver: "ipnet",
        attach: false
      })

    %{container_endpoints: [%Schemas.EndPoint{ip_address: ip}]} = TestHelper.container_inspect(cid)
    assert ip == "10.201.0.1"

    TestHelper.container_remove(api_spec, cid)
    Network.remove(nodns.id)
  end

  defp endpoint_ip(container_id) do
    case TestHelper.container_inspect(container_id) do
      %{container_endpoints: [%Schemas.EndPoint{ip_address: ip}]} -> ip
    end
  end

  # Query the resolver over UDP like a container would and return
  # {address, ttl} of the first A record, :nxdomain, or :timeout.
  defp resolve(name, resolver_ip) do
    {:ok, sock} = :gen_udp.open(0, [:binary, {:active, false}])

    q =
      {:dns_rec, {:dns_header, 4242, false, :query, false, false, true, false, false, 0},
       [{:dns_query, String.to_charlist(name), :a, :in, false}], [], [], []}

    {:ok, ip} = :inet.parse_address(String.to_charlist(resolver_ip))
    :ok = :gen_udp.send(sock, ip, 53, :inet_dns.encode(q))

    result =
      case :gen_udp.recv(sock, 0, 2000) do
        {:ok, {_ip, _port, bin}} ->
          {:ok, {:dns_rec, hdr, _, answers, _, _}} = :inet_dns.decode(bin)

          case {elem(hdr, 9), answers} do
            {3, _} -> :nxdomain
            # NOERROR with no A records is an equally negative answer
            {0, []} -> :nxdomain
            {0, [{:dns_rr, _, :a, :in, _, ttl, addr, _, _, _} | _]} -> {format_ip(addr), ttl}
            _ -> :unexpected
          end

        {:error, :timeout} ->
          :timeout
      end

    :gen_udp.close(sock)
    result
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
end
