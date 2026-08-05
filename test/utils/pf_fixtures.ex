defmodule Kleened.Test.PfFixtures do
  @moduledoc """
  Builders for exercising `Kleened.Core.Network.build_pf_config/1`.

  Shared by the generation tests (`pf_config_test.exs`, which assert on the
  rendered text) and the load tests (`pf_load_test.exs`, which feed the result to
  `pfctl -n -f` and assert on what pf itself parses).
  """

  alias Kleened.Core.Network
  alias Kleened.API.Schemas

  @doc """
  A copy of `example/pf.conf.kleene`'s placeholders.

  Kept inline rather than read from disk so the tests do not depend on a file a
  developer may have edited, and so they stay in the unprivileged tier.
  """
  def template do
    """
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
  end

  @doc "Render a pf config from the given overrides, defaulting everything else."
  def build(opts \\ []) do
    Network.build_pf_config(%{
      networks: Keyword.get(opts, :networks, []),
      network_endpoints: Keyword.get(opts, :network_endpoints, %{}),
      containers: Keyword.get(opts, :containers, []),
      host_gateway: Keyword.get(opts, :host_gateway, "em0"),
      host_gw: Keyword.get(opts, :host_gw, "em0"),
      template: Keyword.get(opts, :template, template())
    })
  end

  def network(attrs \\ []) do
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

  def container_with_ports(pub_ports) do
    %Schemas.Container{id: "conid", name: "testcon", public_ports: pub_ports}
  end

  def published_port(attrs \\ []) do
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

  @doc """
  Body of one of the template's sections, e.g. "TRANSLATION" or "FILTERING".
  """
  def section(config, name) do
    [_before, rest] = String.split(config, "### KLEENED #{name}", parts: 2)
    [body, _after] = String.split(rest, "### KLEENED #{name}", parts: 2)
    body |> String.split("\n", parts: 2) |> List.last()
  end
end
