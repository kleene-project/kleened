defmodule PfBackupTest do
  @moduledoc """
  `Network.backup_foreign_pf_config/1` preserves a pf configuration kleened did
  not generate itself, recognized by the absence of the header line kleened
  writes at the top of every pf configuration file.

  Filesystem-only tests over explicit paths: no MetaData, no Config agent and
  no running host, hence part of the fast :unit tier (runs with --no-start and
  without root).
  """
  use ExUnit.Case

  alias Kleened.Core.Network

  @moduletag :unit
  @moduletag :capture_log

  @kleene_pf_header "# This pf configuration file is managed by kleened; manual changes are overwritten."

  # 'dir' must be bound outside the test body: the after-block of a test macro
  # cannot see variables bound inside it, so the cleanup lives in this helper.
  defp with_pf_conf(contents, fun) do
    dir = Path.join(System.tmp_dir!(), "kleene_pf_backup_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    pf_conf = Path.join(dir, "pf.conf")
    if contents, do: File.write!(pf_conf, contents)

    try do
      fun.(pf_conf)
    after
      File.rm_rf!(dir)
    end
  end

  test "a foreign pf.conf is backed up next to itself" do
    with_pf_conf("pass in proto tcp from any to any port 22\n", fn pf_conf ->
      :ok = Network.backup_foreign_pf_config(pf_conf)

      assert File.read!(pf_conf <> ".kleene.bak") =~ "port 22"
    end)
  end

  test "no pf.conf means no backup" do
    with_pf_conf(nil, fn pf_conf ->
      :ok = Network.backup_foreign_pf_config(pf_conf)

      refute File.exists?(pf_conf <> ".kleene.bak")
    end)
  end

  test "a kleened-generated pf.conf (carrying the header) is not backed up" do
    contents = """
    #{@kleene_pf_header}
    ### KLEENED MACROS START ###
    rdr on lo0 inet proto tcp from any to any port 8080 -> 10.13.37.2 port 80
    """

    with_pf_conf(contents, fn pf_conf ->
      :ok = Network.backup_foreign_pf_config(pf_conf)

      refute File.exists?(pf_conf <> ".kleene.bak")
    end)
  end

  test "an existing backup is never overwritten" do
    with_pf_conf("pass in proto tcp from any to any port 22\n", fn pf_conf ->
      backup = pf_conf <> ".kleene.bak"
      File.write!(backup, "the original host configuration\n")

      :ok = Network.backup_foreign_pf_config(pf_conf)

      assert File.read!(backup) == "the original host configuration\n"
    end)
  end
end
