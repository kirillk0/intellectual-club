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

  test "truncated background status pages expose only the safe retry cursor" do
    result = %ExecutionResult{
      text: String.duplicate("large progress payload ", 500),
      raw: %{
        "background_task" => %{
          "background_task_id" => "5f402355-0c1c-4ef2-a0d0-cf0bc066c513",
          "kind" => "ssh_command",
          "status" => "running",
          "progress" => [
            %{
              "cursor" => "page-end",
              "type" => "stdout",
              "mode" => "append",
              "text" => String.duplicate("x", 2_000)
            }
          ],
          "next_cursor" => "page-end",
          "result" => nil,
          "error" => nil,
          "status_detail" => "still_running",
          "created_at" => "2026-07-12T10:00:00Z",
          "updated_at" => "2026-07-12T10:01:00Z"
        },
        "background_task_request" => %{"operation" => "check", "cursor" => "page-start"}
      },
      media: [],
      artifacts: []
    }

    limited = Executor.limit_execution_result(result, 100)
    snapshot = limited.raw["background_task"]

    assert String.starts_with?(limited.text, "RETRY THE STATUS CHECK WITH THE SAME CURSOR")
    refute limited.text =~ "page-end"
    assert limited.raw["truncated"] == true
    assert snapshot["response_truncated"] == true
    assert snapshot["page_consumed"] == false
    assert snapshot["progress"] == []
    refute Map.has_key?(snapshot, "next_cursor")

    assert snapshot["retry"] == %{
             "operation" => "check_background_task_status",
             "cursor" => "page-start",
             "omit_cursor" => false
           }

    zero_limit = Executor.limit_execution_result(result, 0)
    assert zero_limit.text == "PAGE_NOT_CONSUMED; RETRY_SAME_CURSOR; DO_NOT_ADVANCE."
    refute Map.has_key?(zero_limit.raw["background_task"], "next_cursor")
  end

  test "truncated cancellation response confirms cancellation and retries status without cursor" do
    result = %ExecutionResult{
      text: String.duplicate("large cancellation snapshot ", 500),
      raw: %{
        "background_task" => %{
          "background_task_id" => "bd6a75ee-384c-4526-8bdd-6e81c04349c0",
          "kind" => "fork",
          "status" => "running",
          "progress" => [%{"cursor" => "page-end", "type" => "answer", "mode" => "replace"}],
          "next_cursor" => "page-end"
        },
        "background_task_request" => %{"operation" => "cancel", "cursor" => nil}
      },
      media: [],
      artifacts: []
    }

    limited = Executor.limit_execution_result(result, 100)
    snapshot = limited.raw["background_task"]

    assert String.starts_with?(limited.text, "CANCELLATION WAS REQUESTED")
    refute limited.text =~ "page-end"
    assert snapshot["page_consumed"] == false
    refute Map.has_key?(snapshot, "next_cursor")

    assert snapshot["retry"] == %{
             "operation" => "check_background_task_status",
             "cursor" => nil,
             "omit_cursor" => true
           }
  end

  test "oversized terminal background results are bounded without a retry cursor loop" do
    for kind <- ["fork", "ssh_command", "outlet_function"] do
      result = %ExecutionResult{
        text: String.duplicate("terminal answer ", 2_000),
        raw: %{
          "background_task" => %{
            "background_task_id" => "2a0e122f-e092-4d3b-9581-aa2ce769d7e1",
            "kind" => kind,
            "status" => "completed",
            "progress" => [
              %{
                "cursor" => "page-end",
                "type" => "stdout",
                "text" => "last progress"
              }
            ],
            "next_cursor" => "page-end",
            "result" => %{
              "text" => String.duplicate("terminal answer ", 2_000),
              "raw" => %{
                "exit_code" => 0,
                "stdout" => String.duplicate("command output ", 2_000)
              },
              "media" => [],
              "artifacts" => []
            },
            "error" => nil,
            "created_at" => "2026-07-12T10:00:00Z",
            "finished_at" => "2026-07-12T10:01:00Z",
            "updated_at" => "2026-07-12T10:01:00Z"
          },
          "background_task_request" => %{"operation" => "check", "cursor" => "page-start"}
        },
        media: [],
        artifacts: []
      }

      limited = Executor.limit_execution_result(result, 600)
      snapshot = limited.raw["background_task"]

      assert String.starts_with?(limited.text, "BACKGROUND TASK IS TERMINAL")
      refute limited.text =~ "RETRY THE STATUS CHECK"
      assert limited.raw["terminal_result_truncated"] == true
      assert snapshot["status"] == "completed"
      assert snapshot["response_truncated"] == true
      assert snapshot["page_consumed"] == true
      assert snapshot["terminal_result_truncated"] == true
      assert snapshot["next_cursor"] == "page-end"

      assert snapshot["progress"] == [
               %{"cursor" => "page-end", "type" => "stdout", "text" => "last progress"}
             ]

      assert snapshot["result"]["truncated"] == true
      assert snapshot["result"]["raw"]["exit_code"] == 0
      assert snapshot["result"]["raw"]["stdout"]["truncated"] == true
      refute Map.has_key?(snapshot, "retry")
      assert IntellectualClub.TokenCounter.estimate(limited.text) <= 600
    end
  end

  test "an empty terminal progress page is consumed even with a tiny output limit" do
    result = %ExecutionResult{
      text: String.duplicate("terminal answer ", 100),
      raw: %{
        "background_task" => %{
          "background_task_id" => "94716147-37c4-4e47-9059-002789a265b1",
          "kind" => "fork",
          "status" => "completed",
          "progress" => [],
          "next_cursor" => "0",
          "result" => %{"text" => String.duplicate("terminal answer ", 100)}
        },
        "background_task_request" => %{"operation" => "check", "cursor" => nil}
      },
      media: [],
      artifacts: []
    }

    limited = Executor.limit_execution_result(result, 0)

    assert limited.text =~ "BACKGROUND_TASK_TERMINAL"
    assert limited.raw["background_task"]["page_consumed"] == true
    refute Map.has_key?(limited.raw["background_task"], "retry")
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
