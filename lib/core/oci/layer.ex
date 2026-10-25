defmodule Kleened.Core.OCI.Layer do
  @moduledoc """
  Whiteout-aware application of OCI image layers onto a filesystem.

  A layer is a (possibly gzipped) tar archive. Applying it means:

  1. reading the entry list,
  2. processing OCI whiteouts: `dir/.wh.<name>` deletes `dir/<name>` from the
     lower layers, `dir/.wh..wh..opq` removes all existing children of `dir`
     (the directory becomes opaque),
  3. extracting the remaining entries over `dest`.

  Extraction shells out to bsdtar (`/usr/bin/tar -xpf`) rather than
  `:erl_tar.extract/2`: the latter rejects relative symlinks that escape the
  extraction root (`usr/bin/ld -> ../../libexec/ld-elf.so.1`) as unsafe, which
  real FreeBSD images contain (found during the phase-0 spike).
  """

  alias Kleened.Core.OS

  @whiteout_prefix ".wh."
  @opaque_marker ".wh..wh..opq"

  @doc """
  Apply the layer tar at `layer_path` on top of the filesystem rooted at `dest`.
  """
  @spec apply(Path.t(), Path.t()) :: :ok | {:error, String.t()}
  def apply(layer_path, dest) do
    with {:ok, entries} <- tar_entries(layer_path),
         :ok <- apply_whiteouts(dest, entries) do
      extract(layer_path, dest)
    end
  end

  defp tar_entries(layer_path) do
    case OS.cmd(["/usr/bin/tar", "-tf", layer_path]) do
      {output, 0} ->
        entries =
          output
          |> String.split("\n")
          |> Enum.map(&normalize_entry/1)
          |> Enum.reject(&(&1 == "" or &1 == "."))

        {:ok, entries}

      {output, _exitcode} ->
        {:error, "could not list layer #{layer_path}: #{output}"}
    end
  end

  # bsdtar lists entries with a `./` prefix and directories with a trailing
  # slash — strip both so whiteout matching sees `a/.wh.gone`.
  defp normalize_entry(entry) do
    entry
    |> String.trim_trailing("/")
    |> case do
      "./" <> name -> name
      name -> name
    end
  end

  defp apply_whiteouts(dest, entries) do
    entries
    |> Enum.filter(&String.contains?(&1, @whiteout_prefix))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      case handle_whiteout(dest, entry) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp handle_whiteout(dest, entry) do
    {dir, basename} = split_entry(entry)
    target_dir = if dir in [".", ""], do: dest, else: Path.join(dest, dir)

    cond do
      basename == @opaque_marker ->
        case File.ls(target_dir) do
          {:ok, children} ->
            Enum.each(children, &File.rm_rf(Path.join(target_dir, &1)))
            :ok

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            {:error, "could not list opaque directory #{target_dir}: #{inspect(reason)}"}
        end

      String.starts_with?(basename, @whiteout_prefix) ->
        target = Path.join(target_dir, String.trim_leading(basename, @whiteout_prefix))

        case File.rm_rf(target) do
          {:ok, _} -> :ok
          {:error, reason, _file} -> {:error, "could not whiteout #{target}: #{inspect(reason)}"}
        end

      true ->
        :ok
    end
  end

  # `tar -tf` lists `dir/.wh.name`-style entries; trailing slashes are already
  # trimmed. A bare basename has no directory part.
  defp split_entry(entry) do
    case String.split(entry, "/", parts: 2) do
      [basename] -> {".", basename}
      [dir, basename] -> {dir, basename}
    end
  end

  defp extract(layer_path, dest) do
    case OS.cmd(["/usr/bin/tar", "-xpf", layer_path, "-C", dest]) do
      {_, 0} ->
        remove_whiteout_artifacts(dest)
        :ok

      {output, _exitcode} ->
        {:error, "could not extract layer #{layer_path} to #{dest}: #{output}"}
    end
  end

  # bsdtar extracts the .wh.* marker files themselves; remove them afterwards.
  defp remove_whiteout_artifacts(dest) do
    find_and_rm_whiteout_files(dest)
    :ok
  end

  defp find_and_rm_whiteout_files(dir) do
    case File.ls(dir) do
      {:ok, children} ->
        Enum.each(children, fn child ->
          path = Path.join(dir, child)

          cond do
            String.starts_with?(child, @whiteout_prefix) ->
              File.rm_rf(path)

            File.dir?(path) ->
              find_and_rm_whiteout_files(path)

            true ->
              :ok
          end
        end)

      {:error, _} ->
        :ok
    end
  end
end
