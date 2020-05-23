defmodule DockerfileTest do
  import Jocker.Engine.Dockerfile
  use ExUnit.Case

  @moduletag :capture_log

  test "from instruction" do
    test1 = parse("# Testing\nFROM lol\n# One more comment")
    test2 = parse("# Testing\nFROM lol AS maxlol\n# One more comment")
    assert [{:from, "lol"}] == test1
    assert [{:from, "lol", "maxlol"}] == test2
  end

  test "run instruction" do
    test1 = parse("# Testing\nFROM lol\nRUN cat lol.txt")
    test2 = parse("# Testing\nFROM lol\nRUN [\"/bin/sh\", \"-c\", \"cat lol.txt\"]")
    assert [{:from, "lol"}, {:run, ["/bin/sh", "-c", "cat lol.txt"]}] == test1
    assert [{:from, "lol"}, {:run, ["/bin/sh", "-c", "cat lol.txt"]}] == test2
  end

  test "cmd instruction" do
    test1 = parse("# Testing\nFROM lol\nCMD cat lol.txt")
    test2 = parse("# Testing\nFROM lol\nCMD [\"/bin/sh\", \"-c\", \"cat lol.txt\"]")
    assert [{:from, "lol"}, {:cmd, ["/bin/sh", "-c", "cat lol.txt"]}] == test1
    assert [{:from, "lol"}, {:cmd, ["/bin/sh", "-c", "cat lol.txt"]}] == test2
  end

  test "expose instruction" do
    test1 = parse("# Testing\nFROM lol\nEXPOSE 1337")
    assert [{:from, "lol"}, {:expose, 1337}] == test1
  end

  test "copy instruction" do
    test1 = parse("# Testing\nFROM lol\nCOPY [\"lol1\", \"lol2\", \"lol3\"]")
    test2 = parse("# Testing\nFROM lol\nCOPY lol1 lol2 lol3")
    assert [{:from, "lol"}, {:copy, ["lol1", "lol2", "lol3"]}] == test1
    assert [{:from, "lol"}, {:copy, ["lol1", "lol2", "lol3"]}] == test2
  end

  test "user instruction" do
    test1 = parse("# Testing\nFROM lol\nUSER testuser")
    test2 = parse("# Testing\nFROM lol\nUSER  testuser  ")
    assert [{:from, "lol"}, {:user, "testuser"}] == test1
    assert [{:from, "lol"}, {:user, "testuser"}] == test2
  end

  test "a real dockerfile" do
    {:ok, file} = File.read("./test/data/test_dockerfile/Dockerfile")
    instructions = parse(file)
    assert [{:from, _} | _] = instructions
  end
end
