defmodule UtilsTest do
  use ExUnit.Case
  import Jocker.Engine.Utils

  test "test duration_to_human_string(now, from)" do
    assert "Less than a second" == duration_to_human_string(10, 10)
    assert "1 second" == duration_to_human_string(10, 9)
    assert "59 seconds" == duration_to_human_string(60, 1)
    assert "About a minute" == duration_to_human_string(61, 1)
    assert "10 minutes" == duration_to_human_string(60 * 10, 1)
    assert "About an hour" == duration_to_human_string(60 * 61, 1)
    hour = 60 * 60
    assert "47 hours" == duration_to_human_string(hour * 47, 1)
    assert "2 days" == duration_to_human_string(hour * 48, 1)
    assert "2 weeks" == duration_to_human_string(hour * 24 * 7 * 2, 1)
    assert "12 months" == duration_to_human_string(hour * 24 * 365, 1)
    assert "2 years" == duration_to_human_string(hour * 24 * 365 * 2, 1)
  end

  test "test human_duration(from_string)" do
    assert "Less than a second" == human_duration(DateTime.to_iso8601(DateTime.utc_now()))
  end
end
