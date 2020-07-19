defmodule EngineUtilsTest do
  use ExUnit.Case
  alias Jocker.Engine.Utils
  import Jocker.Engine.Records

  @moduletag :capture_log

  test "decode buffer" do
    term = {:term, "this is in erlang term"}
    bin = :erlang.term_to_binary(term)
    part1 = String.slice(bin, 0, 10)
    part2 = String.slice(bin, 11, byte_size(bin))
    assert {^term, ""} = Utils.decode_buffer(bin)
    assert {:no_full_msg, ^part1} = Utils.decode_buffer(part1)
    assert {^term, "moredata"} = Utils.decode_buffer(bin <> "moredata")
  end
end
