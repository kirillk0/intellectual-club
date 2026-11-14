defmodule ImageCheckRobustnessTest do
  # Synchronous: the atom table is global, so no other test may load code or
  # create atoms while this one measures it.
  use ExUnit.Case, async: false

  @fixtures Path.expand("fixtures", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp webp_with_chunks(<<"RIFF", _size::32-little, "WEBP", chunks::binary>>, extra) do
    body = "WEBP" <> chunks <> extra
    <<"RIFF", byte_size(body)::32-little, body::binary>>
  end

  defp webp_after_vp8x(
         <<"RIFF", _size::32-little, "WEBP", vp8x::binary-size(18), chunks::binary>>,
         extra
       ) do
    body = "WEBP" <> vp8x <> extra <> chunks
    <<"RIFF", byte_size(body)::32-little, body::binary>>
  end

  defp insert_before_sos(payload, data) do
    {offset, 2} = :binary.match(payload, <<0xFF, 0xDA>>)
    <<head::binary-size(^offset), tail::binary>> = payload
    head <> data <> tail
  end

  defp insert_after_ihdr(<<head::binary-size(33), tail::binary>>, data), do: head <> data <> tail

  defp insert_after_screen(<<_header::binary-size(10), flags, _::binary>> = payload, data) do
    import Bitwise
    offset = 13 + 3 * (1 <<< ((flags &&& 0x07) + 1))
    <<head::binary-size(^offset), tail::binary>> = payload
    head <> data <> tail
  end

  defp put_byte(payload, offset, byte) do
    <<head::binary-size(^offset), _old, tail::binary>> = payload
    <<head::binary, byte, tail::binary>>
  end

  describe "bounded memory" do
    test "payloads made of many tiny structures do not grow the process heap" do
      count = 1_000_000

      payloads = [
        webp_with_chunks(fixture("lossy.webp"), :binary.copy(<<"JUNK", 0::32>>, count)),
        webp_with_chunks(fixture("alpha.webp"), :binary.copy(<<"JUNK", 0::32>>, count)),
        webp_after_vp8x(fixture("alpha.webp"), :binary.copy(<<"JUNK", 0::32>>, count)),
        webp_with_chunks(fixture("animated.webp"), :binary.copy(<<"JUNK", 0::32>>, count)),
        insert_before_sos(fixture("baseline.jpg"), :binary.copy(<<0xFF, 0xFE, 0, 2>>, count)),
        insert_after_ihdr(fixture("rgb.png"), :binary.copy(<<0::32, "tEXt", 0::32>>, count)),
        insert_after_screen(fixture("static.gif"), :binary.copy(<<0x21, 0xFE, 0>>, count))
      ]

      for payload <- payloads do
        parent = self()
        # 4 Mi words (32 MiB on 64-bit) is far below one tuple per structure.
        {pid, ref} =
          :erlang.spawn_opt(fn -> send(parent, {:result, ImageCheck.validate(payload)}) end, [
            :monitor,
            max_heap_size: %{size: 4 * 1024 * 1024, kill: true, error_logger: false}
          ])

        assert_receive {:result, {:ok, _info}}, 30_000
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      end
    end
  end

  describe "robustness" do
    test "every prefix and random byte damage of every fixture returns a result" do
      names = File.ls!(@fixtures) |> Enum.reject(&String.ends_with?(&1, ".py"))
      # Load all parser code first: module loading creates atoms, input must not.
      for name <- names,
          do: {ImageCheck.validate(fixture(name)), ImageCheck.header(fixture(name))}

      :rand.seed(:exsss, {1, 2, 3})
      atoms = :erlang.system_info(:atom_count)

      for name <- names do
        payload = fixture(name)

        for size <- 0..byte_size(payload) do
          assert_result(ImageCheck.validate(binary_part(payload, 0, size)))
          assert_result(ImageCheck.header(binary_part(payload, 0, size)))
        end

        for _ <- 1..300 do
          damaged =
            Enum.reduce(1..:rand.uniform(4), payload, fn _, acc ->
              put_byte(acc, :rand.uniform(byte_size(acc)) - 1, :rand.uniform(256) - 1)
            end)

          assert_result(ImageCheck.validate(damaged))
          assert_result(ImageCheck.header(damaged))
        end
      end

      assert :erlang.system_info(:atom_count) == atoms
    end
  end

  defp assert_result({:ok, %{width: width, height: height}})
       when is_integer(width) and is_integer(height),
       do: :ok

  defp assert_result({:error, reason}) when is_atom(reason), do: :ok
  defp assert_result({:error, {format, reason}}) when is_atom(format) and is_atom(reason), do: :ok
  defp assert_result(other), do: flunk("unexpected result #{inspect(other)}")
end
