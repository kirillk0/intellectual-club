defmodule IntellectualClub.Generation.StepRequestsCodecTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.StepRequests
  alias IntellectualClub.Generation.StepRequests.{Codec, Error, Reader}

  test "normalization is opaque, recursive and rejects ambiguous or non-JSON values" do
    assert StepRequests.normalize!(%{role: :user, list: [%{x: nil}, true, 42, 1.25]}) ==
             %{"role" => "user", "list" => [%{"x" => nil}, true, 42, 1.25]}

    for invalid <- [
          [],
          nil,
          %{key: self()},
          %{"x" => 1, x: 2},
          %{1 => 1},
          %{x: <<255>>},
          %{x: ~D[2026-01-01]}
        ] do
      assert_raise Error, fn -> StepRequests.normalize!(invalid) end
    end

    assert Codec.hash(%{b: 2, a: %{z: 0, x: 1}}) ==
             Codec.hash(%{"a" => %{"x" => 1, "z" => 0}, "b" => 2})
  end

  test "canonical encoding preserves already materialized integers beyond decimal128 limits" do
    huge = Integer.pow(10, 400) + 123
    request = %{"huge" => huge, "negative" => -huge, "power" => Integer.pow(10, 80)}
    previous = row(1, request)

    assert Codec.decode!(previous) === request
    assert Codec.hash(%{"n" => Integer.pow(10, 80)}) == Codec.hash(%{"n" => 1.0e80})
    assert Codec.hash(%{"n" => -Integer.pow(10, 80)}) == Codec.hash(%{"n" => -1.0e80})

    target = Map.put(request, "next", true)

    attrs =
      Codec.create_attributes(target,
        sequence: 2,
        previous_step: previous,
        previous_request: request
      )

    assert attrs.request_mode == :patch
    assert Codec.decode!(Map.merge(row(2, target), attrs), previous, request) === target
  end

  test "diff and apply preserve escaped keys, unicode, empty keys and changing arrays" do
    source = %{
      "" => [1, 2, 3],
      "a/b~c" => %{"nested/~" => nil},
      "pad" => String.duplicate("x", 4096)
    }

    previous = row(1, source)

    target = %{
      source
      | "" => [nil, %{"0" => ["\u0000", "☃", true]}, false],
        "a/b~c" => %{"nested/~" => [42, 1.5]}
    }

    attrs =
      StepRequests.create_attributes(target,
        sequence: 2,
        previous_step: previous,
        previous_request: source
      )

    assert attrs.request_mode == :patch
    assert attrs.raw_request == %{}
    assert is_list(attrs.request_patch)
    assert Enum.all?(attrs.request_patch, &is_binary(&1["path"]))
    assert Enum.any?(attrs.request_patch, &String.contains?(&1["path"], "~1"))
    assert Codec.decode!(Map.merge(row(2, target), attrs), previous, source) === target
  end

  test "inexact dependency diffs involving overlapping pointer escapes fall back losslessly" do
    source = %{"a/b~c" => %{"~1/~0" => nil}, "pad" => String.duplicate("x", 4096)}
    target = %{source | "a/b~c" => %{"~1/~0" => [42, 1.5]}}
    previous = row(1, source)

    attrs =
      StepRequests.create_attributes(target,
        sequence: 2,
        previous_step: previous,
        previous_request: source
      )

    assert attrs.request_mode == :full
    assert Codec.decode!(Map.merge(row(2, target), attrs), previous, source) === target
  end

  test "arbitrary JSON objects round trip through both encodings" do
    :rand.seed(:exsss, {431, 912, 37})

    Enum.reduce(1..80, {%{}, nil}, fn sequence, {previous_request, previous} ->
      request = %{"payload" => random_json(3), "padding" => String.duplicate("x", 2048)}

      attrs =
        StepRequests.create_attributes(request,
          sequence: sequence,
          previous_step: previous,
          previous_request: previous_request
        )

      current = Map.merge(%{id: sequence, sequence: sequence, chat_message_id: 1}, attrs)
      assert Codec.decode!(current, previous, previous_request) === request
      {request, current}
    end)
  end

  test "patches at or above half of compact full JSON fall back, just below half do not" do
    empty = %{"pad" => "", "x" => 0}
    target = %{empty | "x" => 1}
    bytes = byte_size(Codec.json!(Jsonpatch.diff(empty, target)))
    padding = bytes * 2 - byte_size(Codec.json!(target))
    assert padding > 0

    for {length, mode} <- [{padding - 1, :full}, {padding, :full}, {padding + 1, :patch}] do
      source = %{empty | "pad" => String.duplicate("a", length)}
      target = %{source | "x" => 1}

      attrs =
        StepRequests.create_attributes(target,
          sequence: 2,
          previous_request: source,
          previous_step: row(1, source)
        )

      assert attrs.request_mode == mode
    end
  end

  test "full checkpoints enforce first step, forced boundaries, missing metadata and chain limits" do
    request = %{"padding" => String.duplicate("x", 2048)}
    first = row(1, request)
    assert StepRequests.create_attributes(request).request_mode == :full
    assert StepRequests.create_attributes(request, sequence: 2).request_mode == :full

    assert StepRequests.create_attributes(request,
             sequence: 3,
             previous_step: first,
             previous_request: request
           ).request_mode == :full

    assert StepRequests.create_attributes(request,
             sequence: 2,
             previous_step: first,
             previous_request: request,
             force_full: true
           ).request_mode == :full

    {steps, _last} =
      Enum.map_reduce(1..70, nil, fn sequence, previous ->
        attrs =
          StepRequests.create_attributes(request,
            sequence: sequence,
            previous_step: previous,
            previous_request: request
          )

        row = Map.merge(%{id: sequence, sequence: sequence, chat_message_id: 1}, attrs)
        {row, row}
      end)

    assert steps |> Enum.filter(&(&1.request_mode == :full)) |> Enum.map(& &1.sequence) == [
             1,
             34,
             67
           ]

    assert Enum.all?(steps, &(&1.request_checkpoint_distance <= 32))
    assert map_size(Reader.decode_rows!(steps)) == 70

    second =
      Map.merge(
        row(2, request),
        StepRequests.create_attributes(request,
          sequence: 2,
          previous_step: first,
          previous_request: request,
          max_chain: 1
        )
      )

    assert second.request_mode == :patch

    assert StepRequests.create_attributes(request,
             sequence: 3,
             previous_step: second,
             previous_request: request,
             max_chain: 1
           ).request_mode == :full

    assert_raise Error, fn -> StepRequests.create_attributes(request, max_chain: 33) end
  end

  test "integer versus float cannot be silently lost by the dependency diff" do
    request = %{"pad" => String.duplicate("x", 2048), "value" => 1}
    target = %{request | "value" => 1.0}

    attrs =
      StepRequests.create_attributes(target,
        sequence: 2,
        previous_step: row(1, request),
        previous_request: request
      )

    assert attrs.request_mode == :full
    assert attrs.raw_request === target
    # JSON numbers compare by value; the stricter writer still preserves the
    # requested in-memory numeric representation instead of using an empty diff.
    assert Codec.hash(request) == Codec.hash(target)
  end

  test "legacy full, patches and full checkpoints decode together without legacy hashes" do
    request = %{"padding" => String.duplicate("x", 2048)}
    legacy = %{row(1, request) | request_hash: nil}

    second =
      Map.merge(
        row(2, request),
        StepRequests.create_attributes(request,
          sequence: 2,
          previous_step: legacy,
          previous_request: request
        )
      )

    third = row(3, %{"other" => true})

    assert Reader.decode_rows!([legacy, second, third]) == %{
             1 => request,
             2 => request,
             3 => %{"other" => true}
           }

    assert Codec.decode!(%{row(8, request) | request_hash: nil}) == request
    assert_raise Error, fn -> Codec.decode!(%{legacy | raw_request: nil}) end
  end

  test "gaps, cross-message bases, hashes, distances and malformed encodings fail closed" do
    request = %{"padding" => String.duplicate("x", 2048)}
    first = row(1, request)

    second =
      Map.merge(
        row(2, request),
        StepRequests.create_attributes(request,
          sequence: 2,
          previous_step: first,
          previous_request: request
        )
      )

    assert_raise Error, fn -> Reader.decode_rows!([second]) end
    assert_raise Error, fn -> Reader.decode_rows!([%{first | chat_message_id: 2}, second]) end

    for corrupt <- [
          %{second | request_hash: String.duplicate("0", 64)},
          %{second | request_base_hash: String.duplicate("0", 64)},
          %{second | request_base_sequence: 9},
          %{second | request_checkpoint_distance: 2},
          %{second | raw_request: %{"unexpected" => true}},
          %{second | sequence: 1},
          %{second | request_patch: nil},
          %{first | request_hash: String.duplicate("0", 64)},
          %{first | request_patch: []}
        ] do
      assert_raise Error, fn -> Codec.decode!(corrupt, first, request) end
    end
  end

  test "array paths follow RFC6902, not numeric prefixes or nonexistent remove/test entries" do
    request = %{"a" => [nil, "one"], "01" => true}

    assert Codec.apply_patch!(request, [%{"op" => "replace", "path" => "/01", "value" => false}])[
             "01"
           ] == false

    assert Codec.apply_patch!(request, [%{"op" => "add", "path" => "/a/-", "value" => 2}])["a"] ==
             [nil, "one", 2]

    for path <- ["/a/01", "/a/1x", "/a/+1", "/a/-1", "/a/2", "/a/-", "/a/~2"] do
      assert_raise Error, fn ->
        Codec.apply_patch!(request, [%{"op" => "remove", "path" => path}])
      end
    end

    assert_raise Error, fn ->
      Codec.apply_patch!(request, [%{"op" => "test", "path" => "/a/2", "value" => nil}])
    end
  end

  test "RFC operations include copy/move/test, root replacement and copying the root" do
    request = %{"a" => [1, 2], "b" => %{"x" => true}}

    patch = [
      %{"op" => "test", "path" => "/a/0", "value" => 1},
      %{"op" => "copy", "from" => "/b/x", "path" => "/flag"},
      %{"op" => "move", "from" => "/a/0", "path" => "/a/1"},
      %{"op" => "remove", "path" => "/b"}
    ]

    assert Codec.apply_patch!(request, patch) == %{"a" => [2, 1], "flag" => true}

    assert Codec.apply_patch!(request, [%{"op" => "replace", "path" => "", "value" => %{}}]) ==
             %{}

    assert Codec.apply_patch!(request, [%{"op" => "copy", "from" => "", "path" => "/copy"}])[
             "copy"
           ] == request

    assert Codec.apply_patch!(request, [%{"op" => "move", "from" => "", "path" => ""}]) == request

    assert_raise Error, fn ->
      Codec.apply_patch!(request, [%{"op" => "move", "from" => "/b", "path" => "/b/y"}])
    end
  end

  test "canonical hashes tolerate JSONB numeric spelling without touching the input map" do
    request = %{"large" => 1.0e30, "small" => 1.0e-20, "zero" => -0.0, "whole" => 1.0}
    expanded = %{"large" => Integer.pow(10, 30), "small" => 1.0e-20, "zero" => 0, "whole" => 1}
    assert Codec.hash(request) == Codec.hash(expanded)
    assert StepRequests.create_attributes(request).raw_request === request
  end

  test "canonical bytes and hashes remain stable for escaped strings and decimal JSON numbers" do
    request = %{
      "a" => %{β: :ok},
      "a/b~" => "\u0000\t\n\r\b\f\"\\☃",
      "z" => [1, 1.0, 1.0e30, 1.0e-20, -0.0]
    }

    canonical = ~S({"a":{"β":"ok"},"a/b~":"\u0000\t\n\r\b\f\"\\☃","z":[1,1,1E+30,1E-20,0]})
    expected_hash = :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)

    assert Codec.json!(request) == canonical
    assert Codec.hash(request) == expected_hash
    assert Codec.create_attributes(request).request_hash == expected_hash
    assert Codec.validate_shape!(row(1, request)).request_hash == expected_hash
  end

  test "UTF-8 validation remains strict after long ASCII runs in keys and values" do
    prefix = String.duplicate("ascii", 256)

    for text <- [prefix, prefix <> "☃𐀀\u0000", "☃" <> prefix <> "é"] do
      request = %{text => [text]}
      assert Codec.normalize!(request) === request
      assert Codec.json!(request) == Jason.encode!(request)
    end

    for invalid <- [
          <<255>>,
          <<192, 175>>,
          <<237, 160, 128>>,
          <<244, 144, 128, 128>>,
          <<226, 130>>
        ],
        text <- [prefix <> invalid, invalid <> prefix, prefix <> invalid <> prefix],
        request <- [%{"value" => text}, %{text => true}] do
      assert_raise Error, fn -> Codec.normalize!(request) end
      assert_raise Error, fn -> Codec.hash(request) end
      assert_raise Error, fn -> Codec.create_attributes(request) end
    end
  end

  test "encoding validation resolves a base only after shape validation and returns normalized fields" do
    source = %{"padding" => String.duplicate("x", 2048), "value" => 1}
    target = %{source | "value" => 2}
    first = row(1, source)
    full_resolver = fn _attrs -> flunk("A full or invalid encoding must not resolve a base") end
    assert Codec.validate_encoding!(first, full_resolver) == Map.take(first, Codec.fields())

    assert Codec.validate_encoding!(%{first | request_hash: nil}, full_resolver).request_hash ==
             nil

    attrs =
      Codec.create_attributes(target, sequence: 2, previous_step: first, previous_request: source)

    second = Map.merge(%{id: 2, sequence: 2, chat_message_id: 1}, attrs)

    atom_patch =
      Enum.map(attrs.request_patch, fn op ->
        %{op: op["op"], path: op["path"], value: op["value"]}
      end)

    assert Codec.validate_encoding!(%{second | request_patch: atom_patch}, fn normalized ->
             assert normalized.request_patch == attrs.request_patch
             {first, source}
           end) == attrs

    for invalid <- [
          %{second | request_checkpoint_distance: 33},
          %{second | sequence: 1},
          %{second | request_patch: [%{"op" => "replace", "path" => "/~2", "value" => 2}]}
        ] do
      assert_raise Error, fn -> Codec.validate_encoding!(invalid, full_resolver) end
    end

    for {candidate, base} <- [
          {second, %{source | "value" => 999}},
          {%{second | request_hash: String.duplicate("0", 64)}, source}
        ] do
      assert_raise Error, fn -> Codec.validate_encoding!(candidate, fn _ -> {first, base} end) end
    end
  end

  test "normalized decoding preserves RFC operations and rejects invalid inserted JSON and non-object roots" do
    source = %{"a" => [1, 2], "b" => %{"x" => true}}
    first = row(1, source)

    patch = [
      %{op: "test", path: "/a/0", value: 1},
      %{op: "copy", from: "/b/x", path: "/flag"},
      %{op: "move", from: "/a/0", path: "/a/1"},
      %{op: "remove", path: "/b"},
      %{op: "copy", from: "", path: "/copy"}
    ]

    inner = %{"a" => [2, 1], "flag" => true}
    target = Map.put(inner, "copy", inner)

    step = %{
      id: 2,
      sequence: 2,
      chat_message_id: 1,
      raw_request: %{},
      request_mode: :patch,
      request_patch: patch,
      request_hash: Codec.hash(target),
      request_base_hash: Codec.hash(source),
      request_base_sequence: 1,
      request_checkpoint_distance: 1
    }

    assert Codec.decode!(step, first, source) === target

    assert Codec.validate_encoding!(step, fn _ -> {first, source} end).request_patch ==
             Codec.normalize!(%{patch: patch})["patch"]

    for value <- [[], nil, "scalar", %{"x" => <<255>>}, %{"x" => 1, x: 2}, %{x: self()}] do
      invalid = %{step | request_patch: [%{"op" => "replace", "path" => "", "value" => value}]}
      assert_raise Error, fn -> Codec.decode!(invalid, first, source) end
      assert_raise Error, fn -> Codec.validate_encoding!(invalid, fn _ -> {first, source} end) end
    end
  end

  defp row(sequence, request) do
    Map.merge(
      %{id: sequence, sequence: sequence, chat_message_id: 1},
      StepRequests.create_attributes(request, sequence: sequence, force_full: true)
    )
  end

  defp random_json(0),
    do: Enum.at([nil, true, false, 0, -42, 1.25, "", "☃/~\u0000"], :rand.uniform(8) - 1)

  defp random_json(depth) do
    case :rand.uniform(3) do
      1 -> random_json(0)
      2 -> for _index <- 1..:rand.uniform(4), do: random_json(depth - 1)
      3 -> Map.new(1..:rand.uniform(4), fn index -> {"key/~#{index}", random_json(depth - 1)} end)
    end
  end
end
