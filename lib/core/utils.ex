defmodule Kleened.Core.Utils do
  require Logger

  defmodule CIDR do
    defstruct first: nil,
              last: nil,
              mask: nil

    def parse(cidr) do
      case InetCidr.parse_cidr(cidr) do
        {:ok, {first, last, mask}} ->
          %CIDR{first: first, last: last, mask: mask}

        {:error, _} ->
          case InetCidr.parse_address(cidr) do
            {:ok, ip} ->
              mask =
                case InetCidr.v4?(ip) do
                  true -> 32
                  false -> 128
                end

              %CIDR{first: ip, last: ip, mask: mask}

            {:error, _} ->
              reason = "could not parse cidr block: #{inspect(cidr)}"
              {:error, reason}
          end
      end
    end
  end

  @spec get_os_pid_of_port(port()) :: String.t()
  def get_os_pid_of_port(port) do
    port |> Port.info() |> Keyword.get(:os_pid) |> Integer.to_string()
  end

  def is_container_running?(container_id) do
    output = System.cmd("jls", ["--libxo=json", "-j", container_id], stderr_to_stdout: true)

    case output do
      {_json, 1} -> false
      {_json, 0} -> true
    end
  end

  def touch(path) do
    case System.cmd("/usr/bin/touch", [path], stderr_to_stdout: true) do
      {"", 0} -> true
      _ -> false
    end
  end

  def timestamp_now() do
    DateTime.to_iso8601(DateTime.utc_now())
  end

  def decode_tagname(nametag) do
    case String.split(nametag, ":") do
      [""] ->
        {"", ""}

      [name] ->
        {name, "latest"}

      [name, tag] ->
        {name, tag}
    end
  end

  def decode_snapshot(nametagsnapshot) do
    case String.split(nametagsnapshot, "@") do
      [nametag] -> {nametag, ""}
      [nametag, snapshot] -> {nametag, "@" <> snapshot}
    end
  end

  def merge_environment_variable_lists(envlist1, envlist2) do
    # list2 overwrites environment varibles from list1
    map1 = envlist2map(envlist1)
    map2 = envlist2map(envlist2)
    Map.merge(map1, map2) |> map2envlist()
  end

  def envlist2map(envs) do
    convert = fn envvar ->
      List.to_tuple(String.split(envvar, "=", parts: 2))
    end

    Map.new(Enum.map(envs, convert))
  end

  def map2envlist(env_map) do
    Map.to_list(env_map) |> Enum.map(fn {name, value} -> Enum.join([name, value], "=") end)
  end

  def uuid() do
    uuid_all = uuid4()
    <<uuid::binary-size(12), _rest::binary>> = uuid_all

    # This way we avoid ever getting uuids that could be interpreted as an integer (by, e.g., /usr/sbin/jail)
    case Integer.parse(uuid) do
      {_integer, ""} -> uuid()
      _ -> uuid
    end
  end

  def human_duration("") do
    ""
  end

  def human_duration(from_string) do
    now = DateTime.to_unix(DateTime.utc_now())
    {:ok, from_datetime, 0} = DateTime.from_iso8601(from_string)
    from = DateTime.to_unix(from_datetime)
    duration_to_human_string(now, from)
  end

  def duration_to_human_string(now, from) do
    duration_seconds = now - from
    duration_minutes = round(duration_seconds / 60)
    duration_hours = round(duration_minutes / 60)

    cond do
      duration_seconds == 0 ->
        "Less than a second"

      duration_seconds == 1 ->
        "1 second"

      duration_seconds < 60 ->
        "#{duration_seconds} seconds"

      duration_minutes == 1 ->
        "About a minute"

      duration_minutes < 60 ->
        "#{duration_minutes} minutes"

      duration_hours == 1 ->
        "About an hour"

      duration_hours < 48 ->
        "#{duration_hours} hours"

      duration_hours < 24 * 7 * 2 ->
        "#{round(duration_hours / 24)} days"

      duration_hours < 24 * 30 * 2 ->
        "#{round(duration_hours / 24 / 7)} weeks"

      duration_hours < 24 * 365 * 2 ->
        "#{round(duration_hours / 24 / 30)} months"

      true ->
        "#{round(duration_hours / 24 / 365)} years"
    end
  end

  ### From 'elixir_uuid' package:
  # Variant, corresponds to variant 1 0 of RFC 4122.
  @variant10 2
  # UUID v4 identifier.
  @uuid_v4 4
  def uuid4() do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)

    <<u0::48, @uuid_v4::4, u1::12, @variant10::2, u2::62>>
    |> uuid_to_string()
  end

  defp uuid_to_string(<<_::128>> = u) do
    IO.iodata_to_binary(for <<part::4 <- u>>, do: e(part))
  end

  defp e(0), do: ?0
  defp e(1), do: ?1
  defp e(2), do: ?2
  defp e(3), do: ?3
  defp e(4), do: ?4
  defp e(5), do: ?5
  defp e(6), do: ?6
  defp e(7), do: ?7
  defp e(8), do: ?8
  defp e(9), do: ?9
  defp e(10), do: ?a
  defp e(11), do: ?b
  defp e(12), do: ?c
  defp e(13), do: ?d
  defp e(14), do: ?e
  defp e(15), do: ?f
end
