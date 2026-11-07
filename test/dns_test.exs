defmodule DnsTest do
  use ExUnit.Case
  alias Kleened.Core.DNS

  @moduletag :capture_log
  # The record-level tests are pure: no sockets, no MetaData, no daemon.
  @moduletag :unit

  # A decoded query for "web" A IN, as :inet_dns.decode produces it.
  defp query_hdr do
    {:dns_header, 40253, false, :query, false, false, true, false, false, 0}
  end

  defp query(name, type) do
    {:dns_rec, query_hdr(), [{:dns_query, name, type, :in, false}], [], [], []}
  end

  # Note: :inet_dns.encode/1 returns the binary directly, while decode
  # returns {:ok, rec}.
  defp roundtrip(rec) do
    assert {:ok, decoded} = :inet_dns.decode(:inet_dns.encode(rec))
    decoded
  end

  describe "answer/1 (pure)" do
    test "a known name resolves to the given addresses" do
      {:dns_rec, hdr, [q], [rr], [], []} =
        roundtrip(DNS.answer(%{query: query(~c"web", :a), addrs: [{10, 0, 0, 2}]}))

      # qr (0-based elem 2) and aa (0-based elem 4) are set, rcode 0
      assert elem(hdr, 2) == true
      assert elem(hdr, 4) == true
      assert elem(hdr, 9) == 0

      assert q == {:dns_query, ~c"web", :a, :in, false}
      # decode normalizes the bm field to []
      assert {:dns_rr, ~c"web", :a, :in, 0, 0, {10, 0, 0, 2}, :undefined, [], false} = rr
    end

    test "an aaaa query answers with the ipv6 tuple" do
      {:dns_rec, _, _, [rr], [], []} =
        roundtrip(
          DNS.answer(%{
            query: query(~c"web", :aaaa),
            addrs: [{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}]
          })
        )

      assert {:dns_rr, ~c"web", :aaaa, :in, 0, 0, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, :undefined,
              [], false} = rr
    end

    test "an unknown name yields NXDOMAIN" do
      {:dns_rec, hdr, _, [], [], []} =
        roundtrip(DNS.answer(%{query: query(~c"nope", :a), addrs: []}))

      assert elem(hdr, 2) == true
      assert elem(hdr, 4) == true
      # rcode 3 = NXDOMAIN
      assert elem(hdr, 9) == 3
    end

    test "multiple addresses produce multiple answer records" do
      {:dns_rec, _, _, [rr1, rr2], [], []} =
        roundtrip(
          DNS.answer(%{query: query(~c"web", :a), addrs: [{10, 0, 0, 2}, {10, 0, 0, 3}]})
        )

      assert {:dns_rr, _, _, _, _, _, {10, 0, 0, 2}, _, _, _} = rr1
      assert {:dns_rr, _, _, _, _, _, {10, 0, 0, 3}, _, _, _} = rr2
    end
  end
end
