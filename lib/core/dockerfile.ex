defmodule Kleened.Core.Dockerfile do
  import String, only: [replace: 3, split: 2, split: 3, trim: 1]
  require Logger

  def parse(dockerfile) do
    instructions = decode_file(dockerfile)

    case verify_instructions(instructions) do
      :ok ->
        {:ok, instructions}

      # {:error, {:illegal_before_from, line}} ->
      #  [{line, {:error, "instruction not permitted before a FROM instruction"}}]
      {:error, error_msg} ->
        {:error, error_msg}
    end
  end

  defp verify_instructions([]) do
    :ok
  end

  defp verify_instructions([{line, {:env, {:error, msg}}} | _rest]) do
    {:error, "#{msg} on line: #{line}"}
  end

  defp verify_instructions([{line, {:arg, {:error, msg}}} | _rest]) do
    {:error, "#{msg} on line: #{line}"}
  end

  defp verify_instructions([{line, {:error, reason}} | _rest]) do
    {:error, "error in '#{line}': #{reason}"}
  end

  defp verify_instructions([{_line, _instruction} | rest]) do
    verify_instructions(rest)
  end

  def decode_file(dockerfile) do
    dockerfile
    # Remove escaped newlines
    |> replace("\\\n", "")
    # Remove empty lines
    |> split("\n")
    |> Enum.filter(&remove_blanks_and_comments/1)
    |> Enum.map(&decode_line/1)
  end

  defp remove_blanks_and_comments(<<?#, _rest::binary>>), do: false

  defp remove_blanks_and_comments(line) do
    case String.trim(line) do
      "" -> false
      _ -> true
    end
  end

  defp decode_line(instruction_line) do
    instr =
      case split(instruction_line, " ", parts: 2) do
        [instruction, args] ->
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

            _unknown_instruction ->
              Logger.debug("Invalid instruction: #{instruction_line}")
              {:error, "invalid instruction"}
          end

        _ ->
          Logger.debug("Could not decode instruction: #{instruction_line}")
          {:error, "invalid instruction"}
      end

    {instruction_line, instr}
  end

  defp decode_from_args(args) do
    case split(args, " AS ") do
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
