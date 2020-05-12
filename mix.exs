defmodule Jocker.MixProject do
  use Mix.Project

  def project do
    [
      app: :jocker,
      version: "0.1.0",
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
      {:elixir_uuid, "~> 1.2"},
      {:amnesia, "~> 0.2.8"},
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false},
      {:earmark, "~> 1.4.4", only: :dev},
      {:ex_doc, "~> 0.19", only: :dev},
      {:excoveralls, "~> 0.12", only: :test}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
