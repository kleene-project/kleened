defmodule Jocker.Engine.Dockerfile do
  import String, only: [replace: 3, split: 2, split: 3, trim: 1, to_integer: 1]

  def parse(dockerfile) do
    {:ok, tokens} = decode_file(dockerfile)
    :ok = starts_with_from_instruction(tokens)
    tokens
  end

  defp starts_with_from_instruction([instruction | rest]) do
    case instruction do
      {:arg, _} ->
        starts_with_from_instruction(rest)

      {:from, _} ->
        :ok

      {:from, _, _} ->
        :ok
    end
  end

  def decode_file(dockerfile) do
    instructions =
      dockerfile
      # Remove escaped newlines
      |> replace("\\\n", "")
      # Remove empty lines
      |> split("\n")
      |> Enum.filter(&remove_blanks_and_comments/1)
      |> Enum.map(&decode_line/1)

    {:ok, instructions}
  end

  defp remove_blanks_and_comments(<<?#, _rest::binary>>), do: false
  defp remove_blanks_and_comments(""), do: false
  defp remove_blanks_and_comments(_), do: true

  defp decode_line(instruction_line) do
    [instruction, args] = split(instruction_line, " ", parts: 2)

    case {instruction, args} do
      {"USER", user} ->
        {:user, trim(user)}

      {"RUN", <<"[", _::binary>> = json_cmd} ->
        {:run, json_decode(json_cmd)}

      {"RUN", shellform} ->
        {:run, ["/bin/sh", "-c", shellform]}

      {"CMD", <<"[", _::binary>> = json_cmd} ->
        {:cmd, json_decode(json_cmd)}

      {"CMD", shellform} ->
        {:cmd, ["/bin/sh", "-c", shellform]}

      {"COPY", <<"[", _::binary>> = json_form} ->
        {:copy, json_decode(json_form)}

      {"COPY", args} ->
        {:copy, split(args, " ")}

      {"EXPOSE", port} ->
        {:expose, to_integer(port)}

      {"FROM", args} ->
        decode_from_args(args)

      {"VOLUME", args} ->
        {:volume, args}

      unknown_instruction ->
        IO.puts("WARNING: Instruction '#{unknown_instruction}' not understood\n")
        {:unparsed, unknown_instruction}
    end
  end

  defp decode_from_args(args) do
    case split(args, " AS ") do
      ["scratch"] ->
        {:from, "base"}

      [image] ->
        {:from, image}

      [image, name] ->
        {:from, image, name}
    end
  end

  defp json_decode(json) do
    {:ok, valid_json} = Jason.decode(json)
    valid_json
  end
end
