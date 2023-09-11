defmodule Kleened.Core.Dockerfile do
  import String, only: [replace: 3, split: 2, split: 3, trim: 1]
  require Logger

  def parse(dockerfile) do
    {:ok, tokens} = decode_file(dockerfile)
    :ok = starts_with_from_instruction(tokens)
    tokens
  end

  defp starts_with_from_instruction([instruction | rest]) do
    case instruction do
      {_line, {:arg, _}} ->
        starts_with_from_instruction(rest)

      {_line, {:from, _}} ->
        :ok

      {_line, {:from, _, _}} ->
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

    instr =
      case {instruction, args} do
        {"FROM", args} ->
          decode_from_args(args)

        {"USER", user} ->
          {:user, trim(user)}

        {"ENV", env_var} ->
          {:env, clean_envvar(env_var)}

        {"ARG", arg_var} ->
          {:arg, clean_argvar(arg_var)}

        {"WORKDIR", workdir} ->
          {:workdir, workdir}

        {"RUN", <<"[", _::binary>> = json_cmd} ->
          {:run, {:exec_form, json_decode(json_cmd)}}

        {"RUN", shellform} ->
          {:run, {:shell_form, ["/bin/sh", "-c", shellform]}}

        {"CMD", <<"[", _::binary>> = json_cmd} ->
          {:cmd, json_decode(json_cmd)}

        {"CMD", shellform} ->
          {:cmd, ["/bin/sh", "-c", shellform]}

        {"COPY", <<"[", _::binary>> = json_form} ->
          {:copy, json_decode(json_form)}

        {"COPY", args} ->
          {:copy, split(args, " ")}

        _unknown_instruction ->
          Logger.debug("Invalid instruction: #{instruction_line}")
          {:unparsed, instruction_line}
      end

    {instruction_line, instr}
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

  defp clean_envvar(env_var) do
    [varname, value] = String.split(env_var, "=", parts: 2)
    value = String.trim(value, "\"")

    validate_env_name(varname, value)
  end

  defp clean_argvar(arg_var) do
    arg_var = String.trim(arg_var)

    {varname, value} =
      case String.split(arg_var, "=", parts: 2) do
        [varname] -> {varname, ""}
        [varname, default_value] -> {varname, String.trim(default_value, "\"")}
      end

    validate_env_name(varname, value)
  end

  defp validate_env_name(varname, value) do
    # POSIX requirements for env. variable name:
    case String.match?(varname, ~r/^[a-zA-Z_][a-zA-Z0-9_]+$/) do
      true ->
        "#{varname}=#{value}"

      false ->
        {:error, "ENV/ARG variable name is invalid"}
    end
  end
end
