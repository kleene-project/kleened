defmodule Jocker.Engine.Utils do
  require Logger

  def timestamp_now() do
    DateTime.to_iso8601(DateTime.utc_now())
  end

  def mount_nullfs(args) do
    {"", 0} = System.cmd("/sbin/mount_nullfs", args)
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

  def uuid() do
    uuid_all = uuid4()
    <<uuid::binary-size(12), _rest::binary>> = uuid_all

    # This way we avoid ever getting uuids that could be interpreted as an integer (by, e.g., /usr/sbin/jail)
    String.replace(uuid, "1", "g")
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
