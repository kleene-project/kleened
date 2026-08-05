defmodule PfConfigTest do
  use ExUnit.Case

  alias Kleened.Core.Network
  alias Kleened.API.Schemas

  @moduletag :capture_log
  # Pure: Network.build_pf_config/1 takes all of its inputs explicitly, so no
  # MetaData, no Config, no filesystem and no running host. Part of the fast tier.
  @moduletag :unit

  # Mirrors example/pf.conf.kleene. Kept inline so the test does not depend on a
  # file that a developer may have edited.
  @template """
  ### KLEENED MACROS START ###
  <%= kleene_macros %>
  ### KLEENED MACROS END #####

  ### KLEENED TRANSLATION RULES START ###
  <%= kleene_translation %>
  ### KLEENED TRANSLATION RULES END #####

  ### KLEENED FILTERING RULES START #####
  <%= kleene_filtering %>
  ### KLEENED FILTERING RULES END #######
  """

  defp build(opts \\ []) do
    Network.build_pf_config(%{
      networks: Keyword.get(opts, :networks, []),
      network_endpoints: Keyword.get(opts, :network_endpoints, %{}),
      containers: Keyword.get(opts, :containers, []),
      host_gateway: Keyword.get(opts, :host_gateway, "em0"),
      host_gw: Keyword.get(opts, :host_gw, "em0"),
      template: @template
    })
  end

  defp network(attrs \\ []) do
    struct!(
      %Schemas.Network{
        id: "netid",
        name: "testnet",
        type: "loopback",
        interface: "kleene0",
        subnet: "10.13.37.0/24",
        subnet6: "",
        gateway: "",
        gateway6: "",
        nat: "",
        icc: true,
        internal: false
      },
      attrs
    )
  end

  defp container_with_ports(pub_ports) do
    %Schemas.Container{id: "conid", name: "testcon", public_ports: pub_ports}
  end

  defp published_port(attrs \\ []) do
    struct!(
      %Schemas.PublishedPort{
        interfaces: ["em0"],
        host_port: "8080",
        container_port: "80",
        protocol: "tcp",
        ip_address: "10.13.37.2",
        ip_address6: ""
      },
      attrs
    )
  end

  describe "macros" do
    test "the host gateway interface becomes a macro" do
      assert build(host_gateway: "vtnet0") =~ ~s(kleenet_host_gw_if="vtnet0")
    end

    test "no host gateway macro when the gateway is unknown" do
      refute build(host_gateway: nil) =~ "kleenet_host_gw_if"
    end

    test "network interfaces are collected into a single macro" do
      config =
        build(
          networks: [
            network(id: "a", interface: "kleene0"),
            network(id: "b", interface: "kleene1")
          ]
        )

      assert config =~ ~s(kleenet_network_interfaces="{lo0, kleene0,kleene1}")
    end

    test "no interfaces macro when there are no networks" do
      refute build(networks: []) =~ "kleenet_network_interfaces="
    end
  end

  describe "published ports" do
    test "a published port produces an rdr rule per interface and protocol" do
      config = build(containers: [container_with_ports([published_port()])])

      assert config =~
               "rdr on em0 inet proto tcp from any to (em0) port 8080 -> 10.13.37.2 port 80"
    end

    test "a published port produces a matching pass rule" do
      config = build(containers: [container_with_ports([published_port()])])
      assert config =~ "pass quick on em0 inet proto tcp from any to 10.13.37.2 port 80"
    end

    test "publishing on several interfaces produces a rule for each" do
      config =
        build(containers: [container_with_ports([published_port(interfaces: ["em0", "em1"])])])

      assert config =~ "rdr on em0 inet proto tcp"
      assert config =~ "rdr on em1 inet proto tcp"
    end

    test "the protocol is carried into the rules" do
      config = build(containers: [container_with_ports([published_port(protocol: "udp")])])
      assert config =~ "rdr on em0 inet proto udp"
    end

    test "an IPv6 address produces inet6 rules" do
      config =
        build(
          containers: [
            container_with_ports([published_port(ip_address: "", ip_address6: "fd00::2")])
          ]
        )

      assert config =~ "inet6 proto tcp"
      assert config =~ "fd00::2"
    end

    test "several containers each contribute their own rules" do
      config =
        build(
          containers: [
            container_with_ports([published_port(host_port: "8080", ip_address: "10.13.37.2")]),
            container_with_ports([published_port(host_port: "9090", ip_address: "10.13.37.3")])
          ]
        )

      assert config =~ "port 8080 -> 10.13.37.2"
      assert config =~ "port 9090 -> 10.13.37.3"
    end

    test "no containers means no translation rules" do
      config = build(containers: [])
      translation = section(config, "TRANSLATION")
      assert String.trim(translation) == ""
    end
  end

  describe "container port ranges" do
    test "a host range with a '*' destination expands to the same-sized range" do
      config =
        build(
          containers: [
            container_with_ports([
              published_port(host_port: "8080:8090", container_port: "80:*")
            ])
          ]
        )

      assert config =~ "port 80:90"
    end

    test "'*' is kept in the rdr target but resolved in the filter rules" do
      # pf.conf(5) allows '<port>:*' as a redirection target, meaning "preserve the
      # offset within the range". It is not valid in a filter rule, so only the
      # translation section keeps it verbatim.
      config =
        build(
          containers: [
            container_with_ports([published_port(host_port: "8080", container_port: "80:*")])
          ]
        )

      assert section(config, "TRANSLATION") =~ "-> 10.13.37.2 port 80:*"
      assert section(config, "FILTERING") =~ "to 10.13.37.2 port 80\n"
      refute section(config, "FILTERING") =~ "80:*"
    end
  end

  describe "network isolation" do
    test "icc: false blocks traffic between containers on the network" do
      open = build(networks: [network(icc: true)])
      closed = build(networks: [network(icc: false)])
      refute section(open, "FILTERING") == section(closed, "FILTERING")
    end

    test "internal: true changes the filtering rules" do
      external = build(networks: [network(internal: false)])
      internal = build(networks: [network(internal: true)])
      refute section(external, "FILTERING") == section(internal, "FILTERING")
    end

    test "a NAT'ed network produces a nat rule for its subnet" do
      config = build(networks: [network(nat: "em0", subnet: "10.13.37.0/24")])
      assert section(config, "TRANSLATION") =~ "nat"
    end
  end

  describe "rendering" do
    test "output keeps the template's section markers" do
      config = build()

      for marker <- [
            "### KLEENED MACROS START ###",
            "### KLEENED TRANSLATION RULES START ###",
            "### KLEENED FILTERING RULES START #####"
          ] do
        assert config =~ marker
      end
    end

    test "generation is deterministic for the same inputs" do
      opts = [networks: [network()], containers: [container_with_ports([published_port()])]]
      assert build(opts) == build(opts)
    end
  end

  # Extract the body between a section's START and END markers.
  defp section(config, name) do
    [_before, rest] = String.split(config, "### KLEENED #{name}", parts: 2)
    [body, _after] = String.split(rest, "### KLEENED #{name}", parts: 2)
    body |> String.split("\n", parts: 2) |> List.last()
  end
end
