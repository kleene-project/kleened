defmodule PfLoadTest do
  @moduledoc """
  Feed generated rulesets to pf itself.

  `pf_config_test.exs` asserts on the text Kleene produces, which only proves the
  generator matches *our* idea of pf syntax. These tests hand that text to
  `pfctl -n -f`, which parses it and prints the ruleset it constructed without
  loading anything into the kernel. Assertions are therefore on pf's
  interpretation: macros already expanded, ports canonicalised, pf's own implicit
  defaults filled in.

  Needs root, because pfctl opens a netlink socket. Needs nothing else -- no
  jails, no ZFS, no containers, no daemon -- and takes milliseconds.
  """
  use ExUnit.Case

  import Kleened.Test.PfFixtures

  @moduletag :capture_log

  # Ports deliberately outside /etc/services: pfctl rewrites well-known numbers to
  # their service names (80 becomes "http"), which makes assertions confusing.
  @host_port "15080"
  @container_port "15081"

  defp pfctl_parse(config) do
    path = Path.join(System.tmp_dir!(), "kleene_pf_test_#{:erlang.unique_integer([:positive])}")
    File.write!(path, config)

    try do
      case System.cmd("/sbin/pfctl", ["-n", "-v", "-f", path], stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _} -> {:error, output}
      end
    after
      File.rm(path)
    end
  end

  defp assert_parses(config) do
    case pfctl_parse(config) do
      {:ok, output} ->
        output

      {:error, output} ->
        flunk("pfctl rejected the generated ruleset:\n#{output}\n\nruleset was:\n#{config}")
    end
  end

  test "an empty ruleset is valid" do
    assert_parses(build())
  end

  test "pfctl accepts a published port and builds the rdr rule we asked for" do
    output =
      build(
        containers: [
          container_with_ports([
            published_port(
              interfaces: ["lo0"],
              host_port: @host_port,
              container_port: @container_port
            )
          ])
        ]
      )
      |> assert_parses()

    assert output =~ "rdr on lo0 inet proto tcp"
    assert output =~ "-> 10.13.37.2 port #{@container_port}"
  end

  test "pfctl expands the network-interfaces macro" do
    # The generated ruleset refers to $kleenet_network_interfaces; if the macro
    # were missing or misspelled, pfctl would fail with "macro not defined".
    output =
      build(
        networks: [network(interface: "lo0")],
        containers: [
          container_with_ports([
            published_port(
              interfaces: ["lo0"],
              host_port: @host_port,
              container_port: @container_port
            )
          ])
        ]
      )
      |> assert_parses()

    refute output =~ "$kleenet_network_interfaces"
    assert output =~ "lo0"
  end

  test "a NAT'ed network produces a nat rule pf recognises" do
    output =
      build(networks: [network(interface: "lo0", nat: "lo0", subnet: "10.13.37.0/24")])
      |> assert_parses()

    assert output =~ "nat on lo0"
  end

  test "every icc/internal combination produces a loadable ruleset" do
    for internal <- [true, false], icc <- [true, false], nat <- ["", "lo0"] do
      config =
        build(
          networks: [network(interface: "lo0", internal: internal, icc: icc, nat: nat)],
          host_gw: "lo0"
        )

      case pfctl_parse(config) do
        {:ok, _} ->
          :ok

        {:error, output} ->
          flunk(
            "pfctl rejected internal=#{internal} icc=#{icc} nat=#{inspect(nat)}:\n" <>
              "#{output}\n\nruleset was:\n#{config}"
          )
      end
    end
  end

  test "IPv6 published ports produce a loadable ruleset" do
    build(
      containers: [
        container_with_ports([
          published_port(
            interfaces: ["lo0"],
            ip_address: "",
            ip_address6: "fd00::2",
            host_port: @host_port,
            container_port: @container_port
          )
        ])
      ]
    )
    |> assert_parses()
  end

  test "port ranges produce a loadable ruleset" do
    output =
      build(
        containers: [
          container_with_ports([
            published_port(
              interfaces: ["lo0"],
              host_port: "15080:15090",
              container_port: "16080:*"
            )
          ])
        ]
      )
      |> assert_parses()

    assert output =~ "16080"
  end

  test "the check has teeth: a corrupted ruleset is rejected" do
    # Guards against these tests passing vacuously -- if pfctl accepted anything,
    # everything above would be worthless.
    config = build() <> "\nthis is not valid pf syntax\n"
    assert {:error, output} = pfctl_parse(config)
    assert output =~ "syntax error"
  end

  test "the check has teeth: an undefined macro is rejected" do
    config = build() <> "\npass quick on $no_such_macro all\n"
    assert {:error, _output} = pfctl_parse(config)
  end
end
