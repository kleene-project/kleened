defmodule Jocker.Engine.Utils do
  require Logger

  def is_container_running?(container_id) do
    output = System.cmd("jls", ["--libxo=json", "-j", container_id], stderr_to_stdout: true)

    case output do
      {_json, 1} -> false
      {_json, 0} -> true
    end
  end

  def decode_socket_address(<<"unix://", unix_socket::binary>>) do
    {:unix, unix_socket, 0}
  end

  def decode_socket_address(<<"tcp://", address::binary>>) do
    try do
      case String.split(address, ":") do
        [ipv4_or_host_str, port_str] ->
          port = String.to_integer(port_str)

          result = decode_ip(ipv4_or_host_str, :ipv4)

          case result do
            {:ok, address} -> {:ipv4, address, port}
            # We assume that if it is not a ipv4-address it is probably a hostname instead:
            {:error, _} -> {:hostname, ipv4_or_host_str, port}
          end

        ipv6_addressport ->
          {port_str, ipv6address_splitup} = List.pop_at(ipv6_addressport, -1)

          ipv6_address = ipv6address_splitup |> Enum.join(":")
          {:ok, address} = decode_ip(ipv6_address, :ipv6)

          port = String.to_integer(port_str)
          {:ipv6, address, port}
      end
    rescue
      error_msg ->
        {:error, error_msg}
    end
  end

  def decode_ip(ip, ver) do
    ip_charlist = String.to_charlist(ip)

    case ver do
      :ipv4 -> :inet.parse_ipv4_address(ip_charlist)
      :ipv6 -> :inet.parse_ipv6_address(ip_charlist)
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

  def mount_nullfs(args) do
    {"", 0} = System.cmd("/sbin/mount_nullfs", args)
  end

  def destroy_interface(jocker_if) do
    if interface_exists(jocker_if) do
      {"", _exitcode} = System.cmd("ifconfig", [jocker_if, "destroy"])
    end
  end

  def interface_exists(jocker_if) do
    {json, 0} = System.cmd("netstat", ["--libxo", "json", "-I", jocker_if])

    case Jason.decode(json) do
      {:ok, %{"statistics" => %{"interface" => []}}} -> false
      {:ok, %{"statistics" => %{"interface" => _if_stats}}} -> true
    end
  end

  @spec unmount(String.t()) :: integer()
  def unmount(path) do
    {"", return_code} = System.cmd("/sbin/umount", [path])
    return_code
  end

  def decode_tagname(tagname) do
    case String.split(tagname, ":") do
      [name] ->
        {name, "latest"}

      [name, tag] ->
        {name, tag}
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

  def decode_buffer(buffer) do
    reply =
      try do
        :erlang.binary_to_term(buffer)
      rescue
        ArgumentError ->
          :no_full_msg
      end

    case reply do
      :no_full_msg ->
        {:no_full_msg, buffer}

      _full_reply ->
        buffer_size = byte_size(:erlang.term_to_binary(buffer))
        used_size = byte_size(:erlang.term_to_binary(reply))
        new_buffer = String.slice(buffer, used_size, buffer_size)
        {reply, new_buffer}
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
