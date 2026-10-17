defmodule PfConfigTest do
  use ExUnit.Case

  import Kleened.Test.PfFixtures

  @moduletag :capture_log
  # Pure: Network.build_pf_config/1 takes all of its inputs explicitly, so no
  # MetaData, no Config, no filesystem and no running host. Part of the fast tier.
  @moduletag :unit

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

    test "the interfaces macro is defined even with no networks" do
      # The published-port filter rules reference this macro unconditionally, and
      # pf rejects the whole ruleset when a referenced macro is undefined.
      assert build(networks: []) =~ ~s(kleenet_network_interfaces="{lo0}")
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
    # The two flags are orthogonal and each contributes exactly one thing:
    #   icc       -> whether subnet-to-subnet traffic is passed
    #   internal  -> whether egress off the network is blocked
    # Asserting the rules directly is what makes it possible to reason about the
    # combinations without booting a container for each cell.
    defp filtering(internal, icc) do
      build(
        networks: [network(interface: "kleene0", internal: internal, icc: icc, nat: "em0")],
        host_gw: "em0"
      )
      |> section("FILTERING")
    end

    @icc_pass "pass quick on $kleenet_netid_all_interfaces " <>
                "from $kleenet_netid_subnet to $kleenet_netid_subnet"
    @egress_block "block out quick log on $kleenet_network_interfaces " <>
                    "from $kleenet_netid_subnet"
    @nat_egress_block "block out quick log on $kleenet_netid_nat_if " <>
                        "from $kleenet_netid_subnet"

    test "incoming traffic to the subnet is always blocked by default" do
      for internal <- [true, false], icc <- [true, false] do
        assert filtering(internal, icc) =~ "block in log from any to $kleenet_netid_subnet"
      end
    end

    test "icc: true passes traffic between containers on the network" do
      assert filtering(false, true) =~ @icc_pass
    end

    test "icc: false omits the inter-container pass rule" do
      refute filtering(false, false) =~ @icc_pass
    end

    test "internal: true blocks egress, both generally and via the NAT interface" do
      rules = filtering(true, true)
      assert rules =~ @egress_block
      assert rules =~ @nat_egress_block
    end

    test "internal: false does not block egress" do
      rules = filtering(false, true)
      refute rules =~ @egress_block
      refute rules =~ @nat_egress_block
    end

    test "the two flags are independent" do
      # internal governs egress, icc governs inter-container traffic; neither
      # should disturb the other.
      assert filtering(true, false) =~ @egress_block
      refute filtering(true, false) =~ @icc_pass
      assert filtering(true, true) =~ @egress_block
      assert filtering(true, true) =~ @icc_pass
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
end
