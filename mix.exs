defmodule Jocker.MixProject do
  use Mix.Project

  def project do
    [
      app: :jocker,
      version: "0.0.0",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      escript: [
        main_module: Jocker.CLI.Main,
        name: "jocker",
        app: :logger,
        embed_elixir: true
      ],
      dialyzer: [
        # plt_ignore_apps: [:amnesia],
        ignore_warnings: "config/dialyzer.ignore",
        plt_add_deps: :apps_direct
      ],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Jocker.Engine.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.2"},
      {:sqlitex, "~> 1.7"},
      {:yaml_elixir, "~> 2.4"},
      {:cidr, "~> 1.1"},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:earmark, "~> 1.4.4", only: :dev},
      {:ex_doc, "~> 0.19", only: :dev},
      {:excoveralls, "~> 0.12", only: :test}
    ]
  end
end
