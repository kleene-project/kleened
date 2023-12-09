defmodule DockerfileTest do
  import Kleened.Core.Dockerfile
  use ExUnit.Case

  @moduletag :capture_log

  test "from instruction" do
    test1 = parse("# Testing\nFROM lol\n# One more comment")
    test2 = parse("# Testing\nFROM lol AS maxlol\n# One more comment")
    assert [{"FROM lol", {:from, "lol"}}] == test1
    assert [{"FROM lol AS maxlol", {:from, "lol", "maxlol"}}] == test2
  end

  test "run instruction" do
    output = parse("# Testing\nFROM lol\nRUN cat lol.txt")

    assert output == [
             {"FROM lol", {:from, "lol"}},
             {"RUN cat lol.txt", {:run, ["/bin/sh", "-c", "cat lol.txt"]}}
           ]

    output = parse("# Testing\nFROM lol\nRUN [\"/bin/sh\", \"-c\", \"cat lol.txt\"]")

    assert output ==
             [
               {"FROM lol", {:from, "lol"}},
               {"RUN [\"/bin/sh\", \"-c\", \"cat lol.txt\"]",
                {:run, ["/bin/sh", "-c", "cat lol.txt"]}}
             ]
  end

  test "cmd instruction" do
    test1 = parse("# Testing\nFROM lol\nCMD cat lol.txt")
    test2 = parse("# Testing\nFROM lol\nCMD [\"/bin/sh\", \"-c\", \"cat lol.txt\"]")

    assert test1 == [
             {"FROM lol", {:from, "lol"}},
             {"CMD cat lol.txt", {:cmd, ["/bin/sh", "-c", "cat lol.txt"]}}
           ]

    assert test2 == [
             {"FROM lol", {:from, "lol"}},
             {"CMD [\"/bin/sh\", \"-c\", \"cat lol.txt\"]",
              {:cmd, ["/bin/sh", "-c", "cat lol.txt"]}}
           ]
  end

  test "copy instruction" do
    test1 = parse("# Testing\nFROM lol\nCOPY [\"lol1\", \"lol2\", \"lol3\"]")
    test2 = parse("# Testing\nFROM lol\nCOPY lol1 lol2 lol3")

    assert test1 == [
             {"FROM lol", {:from, "lol"}},
             {"COPY [\"lol1\", \"lol2\", \"lol3\"]", {:copy, ["lol1", "lol2", "lol3"]}}
           ]

    assert test2 == [
             {"FROM lol", {:from, "lol"}},
             {"COPY lol1 lol2 lol3", {:copy, ["lol1", "lol2", "lol3"]}}
           ]
  end

  test "user instruction" do
    test1 = parse("# Testing\nFROM lol\nUSER testuser")
    test2 = parse("# Testing\nFROM lol\nUSER  testuser  ")
    assert test1 == [{"FROM lol", {:from, "lol"}}, {"USER testuser", {:user, "testuser"}}]
    assert test2 == [{"FROM lol", {:from, "lol"}}, {"USER  testuser  ", {:user, "testuser"}}]
  end

  test "a real dockerfile" do
    {:ok, file} = File.read("./test/data/test_dockerfile/Dockerfile")
    instructions = parse(file)
    assert [{_, {:from, _}} | _] = instructions
  end
end
