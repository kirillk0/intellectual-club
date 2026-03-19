defmodule IntellectualClub.Tools.ExecutorTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.Executor

  test "sanitize_execution_result removes null bytes recursively" do
    result = %ExecutionResult{
      text: "ab" <> <<0>> <> "cd",
      raw: %{
        "stdout" => "he" <> <<0>> <> "llo",
        "nested" => [
          %{"value" => <<0>> <> "tail"},
          {"tuple" <> <<0>>, "item" <> <<0>>}
        ]
      },
      media: [%{"filename" => "image" <> <<0>> <> ".png"}],
      artifacts: [%{"path" => "tmp" <> <<0>> <> "/file.bin"}]
    }

    sanitized = Executor.sanitize_execution_result(result)

    assert sanitized.text == "abcd"
    assert sanitized.raw["stdout"] == "hello"
    assert sanitized.raw["nested"] == [%{"value" => "tail"}, {"tuple", "item"}]
    assert sanitized.media == [%{"filename" => "image.png"}]
    assert sanitized.artifacts == [%{"path" => "tmp/file.bin"}]
    refute contains_null_byte?(sanitized)
  end

  defp contains_null_byte?(value) when is_binary(value) do
    :binary.match(value, <<0>>) != :nomatch
  end

  defp contains_null_byte?(%ExecutionResult{} = value) do
    value
    |> Map.from_struct()
    |> contains_null_byte?()
  end

  defp contains_null_byte?(value) when is_list(value) do
    Enum.any?(value, &contains_null_byte?/1)
  end

  defp contains_null_byte?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested_value} ->
      contains_null_byte?(key) or contains_null_byte?(nested_value)
    end)
  end

  defp contains_null_byte?(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.any?(&contains_null_byte?/1)
  end

  defp contains_null_byte?(_value), do: false
end
