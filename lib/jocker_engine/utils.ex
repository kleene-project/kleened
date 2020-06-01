defmodule Jocker.Engine.Utils do
  def timestamp_now() do
    DateTime.to_iso8601(DateTime.utc_now())
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
    uuid_all = UUID.uuid4(:hex)
    <<uuid::binary-size(12), _rest::binary>> = uuid_all
    uuid
  end

  def decode_buffer(buffer) do
    case :erlang.binary_to_term(buffer) do
      :badarg ->
        {:no_full_msg, buffer}

      reply ->
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
end
