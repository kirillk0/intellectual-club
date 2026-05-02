defmodule IntellectualClub.Tools.ExecutorTest do
  use ExUnit.Case, async: false

  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.Executor
  alias IntellectualClub.Tools.RateLimiter
  alias IntellectualClub.Tools.ToolInstance

  setup do
    RateLimiter.reset()
    :ok
  end

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

  test "sanitize_execution_result converts invalid utf-8 recursively" do
    invalid = <<208, 194, 189>>

    result = %ExecutionResult{
      text: "head " <> invalid <> " tail",
      raw: %{
        "stdout" => invalid,
        invalid => %{"nested" => "value " <> invalid},
        "list" => [invalid, {"tuple", invalid}]
      },
      media: [%{"filename" => "image-" <> invalid <> ".png"}],
      artifacts: [%{"path" => "/tmp/" <> invalid <> ".bin"}]
    }

    sanitized = Executor.sanitize_execution_result(result)

    assert sanitized.text == "head ÐÂ½ tail"
    assert sanitized.raw["stdout"] == "ÐÂ½"
    assert sanitized.raw["ÐÂ½"] == %{"nested" => "value ÐÂ½"}
    assert sanitized.raw["list"] == ["ÐÂ½", {"tuple", "ÐÂ½"}]
    assert sanitized.media == [%{"filename" => "image-ÐÂ½.png"}]
    assert sanitized.artifacts == [%{"path" => "/tmp/ÐÂ½.bin"}]
    assert utf8_valid?(sanitized)
  end

  test "limited tool calls pass through when a slot is available" do
    tool = limited_tool_instance()

    result = Executor.execute_llm_tool(%{"web" => tool}, "web__search", %{})

    assert %ExecutionResult{} = result
    assert result.raw["isError"] == true
    refute result.raw["code"] == "tool_busy"
  end

  test "limited tool calls return a tool error when backlog is too large" do
    tool = limited_tool_instance()

    _first = Executor.execute_llm_tool(%{"web" => tool}, "web__search", %{})
    result = Executor.execute_llm_tool(%{"web" => tool}, "web__search", %{})

    assert result.text == "Tool is busy. Try again later."
    assert result.raw["isError"] == true
    assert result.raw["error"] == "tool is busy"
    assert result.raw["code"] == "tool_busy"
  end

  defp limited_tool_instance do
    %ToolInstance{
      id: System.unique_integer([:positive, :monotonic]),
      type: "mcp-http",
      config: %{},
      secrets: %{},
      max_output_tokens: 20_000,
      rps_limit: 0.01
    }
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

  defp utf8_valid?(value) when is_binary(value), do: String.valid?(value)

  defp utf8_valid?(%ExecutionResult{} = value) do
    value
    |> Map.from_struct()
    |> utf8_valid?()
  end

  defp utf8_valid?(value) when is_list(value) do
    Enum.all?(value, &utf8_valid?/1)
  end

  defp utf8_valid?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested_value} ->
      utf8_valid?(key) and utf8_valid?(nested_value)
    end)
  end

  defp utf8_valid?(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.all?(&utf8_valid?/1)
  end

  defp utf8_valid?(_value), do: true
end
