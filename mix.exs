defmodule Mix.Tasks.Compile.RunPty do
  def run(_args) do
    File.mkdir_p!("priv/bin")
    {result, _errcode} = System.cmd("make", ["runpty"], stderr_to_stdout: true)
    IO.binwrite(result)
  end
end

defmodule Kleened.MixProject do
  use Mix.Project

  def project do
    [
      app: :kleened,
      version: "0.1.0",
      elixir: "~> 1.9",
      compilers: Mix.compilers() ++ [:run_pty, :leex, :yecc],
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: [
        kleened: [include_executables_for: [:unix]]
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
      extra_applications: [:logger, :crypto, :eex, :cowboy, :plug],
      mod: {Kleened.Core.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:exqlite, "0.20.0"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.11"},
      {:inet_cidr, "~> 1.0.0"},
      {:cowlib, "~> 2.12", override: true},
      {:plug, "~> 1.12"},
      {:plug_cowboy, "~> 2.5"},
      {:open_api_spex, "~> 3.10"},
      {:earmark, "~> 1.4.4", only: :dev},
      {:ex_doc, "~> 0.34.2", only: :dev},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:excoveralls, "~> 0.15.0", only: :test},
      {:gun, "~> 2.0", only: :test}
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/utils"]
  defp elixirc_paths(_), do: ["lib"]
end
