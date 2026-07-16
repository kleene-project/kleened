defmodule Mix.Tasks.Erlex.Typecheck do
  @shortdoc "Run dialyzer directly (bypasses dialyxir circular dependency)"
  @moduledoc """
  Runs Erlang's Dialyzer directly via the `:dialyzer` module.

  This custom task exists because erlex cannot use dialyxir - dialyxir
  depends on erlex, creating a circular dependency. Instead, we invoke
  the Dialyzer API directly through Elixir.

  ## Usage

      # Run type checking (builds PLT if missing)
      mix erlex.typecheck

      # Build/rebuild the PLT cache
      mix erlex.typecheck --build-plt

      # Clean the PLT cache
      mix erlex.typecheck --clean

  ## Configuration

  The PLT is stored in `priv/plts/dialyzer.plt` and includes the core
  Erlang/Elixir applications: erts, kernel, stdlib, elixir, mix.
  """

  use Mix.Task

  @plt_path "priv/plts/dialyzer.plt"
  @plt_apps [:erts, :kernel, :stdlib, :elixir, :mix]
  @warnings [:error_handling, :underspecs, :unmatched_returns]

  @impl Mix.Task
  def run(["--build-plt"]) do
    ensure_dialyzer_loaded!()
    build_plt()
  end

  def run(["--clean"]) do
    clean_plt()
  end

  def run(_args) do
    ensure_dialyzer_loaded!()
    ensure_compiled()
    ensure_plt()
    run_dialyzer()
  end

  # OTP apps that dialyzer depends on but may not be in the code path under Mix
  @dialyzer_otp_deps [:dialyzer, :syntax_tools, :compiler, :hipe]

  defp ensure_dialyzer_loaded! do
    # Dialyzer is an OTP tool not automatically in code path when running via Mix.
    # We need to find and add its ebin directory (and dependencies) before we can load it.
    otp_lib_dir = :code.root_dir() |> to_string() |> Path.join("lib")

    Enum.each(@dialyzer_otp_deps, fn app ->
      case Path.wildcard(Path.join(otp_lib_dir, "#{app}-*")) do
        # Some apps like hipe may not exist in newer OTP
        [] ->
          :ok

        [app_lib | _] ->
          ebin_path = app_lib |> Path.join("ebin") |> String.to_charlist()
          :code.add_pathz(ebin_path)
      end
    end)

    case Application.ensure_all_started(:dialyzer) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("Failed to load dialyzer: #{inspect(reason)}")
    end
  end

  defp build_plt do
    File.mkdir_p!("priv/plts")
    Mix.shell().info("Building PLT with apps: #{inspect(@plt_apps)}")
    Mix.shell().info("This may take a few minutes...")

    dialyzer_run(
      analysis_type: :plt_build,
      output_plt: plt_charlist(),
      apps: @plt_apps
    )

    Mix.shell().info("PLT built successfully: #{@plt_path}")
  end

  defp clean_plt do
    if File.exists?(@plt_path) do
      File.rm!(@plt_path)
      Mix.shell().info("Removed #{@plt_path}")
    else
      Mix.shell().info("No PLT to clean")
    end
  end

  defp ensure_compiled do
    Mix.Task.run("compile", [])
  end

  defp ensure_plt do
    unless File.exists?(@plt_path) do
      Mix.shell().info("PLT not found, building...")
      build_plt()
    end
  end

  defp run_dialyzer do
    beams =
      "_build/#{Mix.env()}/lib/erlex/ebin/*.beam"
      |> Path.wildcard()
      |> Enum.map(&String.to_charlist/1)

    Mix.shell().info("Analyzing #{length(beams)} beam file(s)...")

    result =
      dialyzer_run(
        analysis_type: :succ_typings,
        init_plt: plt_charlist(),
        files: beams,
        warnings: @warnings
      )

    case result do
      [] ->
        Mix.shell().info("No dialyzer warnings!")
        :ok

      warnings ->
        Enum.each(warnings, fn w ->
          Mix.shell().error(dialyzer_format_warning(w))
        end)

        Mix.raise("Dialyzer found #{length(warnings)} warning(s)")
    end
  end

  # Dynamic calls to avoid compile-time warnings about undefined :dialyzer module
  defp dialyzer_run(opts), do: apply(:dialyzer, :run, [opts])
  defp dialyzer_format_warning(w), do: apply(:dialyzer, :format_warning, [w])

  defp plt_charlist, do: String.to_charlist(@plt_path)
end
