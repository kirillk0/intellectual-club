defmodule IntellectualClub.Generation.RuntimePollTest do
  use ExUnit.Case, async: true
  alias IntellectualClub.Generation.{RuntimePoll, RuntimeTrace}

  defp step do
    RuntimeTrace.new_step(id: 1, sequence: 1)
    |> RuntimeTrace.apply_event({:append_text, "reasoning", :reasoning, 1, "Thinking"})
    |> RuntimeTrace.apply_event({:append_text, "answer", :answer, 1, "Привет 🌍"})
  end

  test "retirement skips even unreadable old trace and resets for a successor or owner" do
    step = step()
    cursor = RuntimePoll.retired_cursor("epoch", step.id, step.sequence)
    unreadable = %{step | items_by_key: :must_not_read, structure_revision: 999}
    reply = RuntimePoll.poll(unreadable, "epoch", cursor)
    assert reply == %{step: nil, stream: %{reset: false, cursor: cursor}}

    for {next, epoch} <- [
          {step, "new epoch"},
          {%{step | id: 2}, "epoch"},
          {%{step | sequence: 2}, "epoch"}
        ] do
      reset = RuntimePoll.poll(next, epoch, cursor)
      assert reset.stream.reset
      assert reset.step.items != []
      refute Map.has_key?(reset.stream.cursor, "retired")
    end

    assert RuntimePoll.poll(step, "epoch", Map.put(cursor, "retired", "true")).stream.reset
  end

  test "a client follows answer by UTF-8 bytes without retaining a snapshot" do
    step = step()
    first = RuntimePoll.poll(step, "epoch", %{})
    assert first.stream.reset
    assert first.stream.cursor["item"] == "answer"
    assert first.stream.cursor["offset"] == byte_size("Привет 🌍")
    next = RuntimeTrace.apply_event(step, {:append_text, "answer", :answer, 1, "!"})
    response = RuntimePoll.poll(next, "epoch", first.stream.cursor)
    refute response.stream.reset
    assert response.step.items == []
    assert response.stream.delta.text == "!"
    assert response.stream.delta.from == byte_size("Привет 🌍")
    assert response.stream.delta.to == byte_size("Привет 🌍!")
    assert RuntimePoll.poll(next, "epoch", first.stream.cursor) == response
    assert RuntimePoll.poll(next, "epoch", response.stream.cursor).stream.delta.text == ""
  end

  test "an existing unselected block can change without rebuilding the step" do
    step = step()
    cursor = RuntimePoll.poll(step, "epoch", %{}).stream.cursor
    next = RuntimeTrace.apply_event(step, {:set_text, "reasoning", :reasoning, 1, "Revised"})
    reply = RuntimePoll.poll(next, "epoch", cursor)
    refute reply.stream.reset
    assert reply.stream.delta.text == ""
    assert reply.stream.cursor == cursor

    assert RuntimePoll.poll(next, "epoch", %{}).step.items
           |> hd()
           |> Map.get(:contents)
           |> hd()
           |> Map.get(:content_text) == "Revised"
  end

  test "the client may explicitly choose reasoning instead of the default answer" do
    step = step()
    initial = RuntimePoll.poll(step, "epoch", %{})
    cursor = Enum.find(initial.stream.targets, &(&1.item_type == "reasoning")).cursor
    step = RuntimeTrace.apply_event(step, {:append_text, "reasoning", :reasoning, 1, " more"})
    assert RuntimePoll.poll(step, "epoch", cursor).stream.delta.text == " more"
  end

  test "same-length replacement, structural change and a new owner reset the cursor" do
    step = step()
    cursor = RuntimePoll.poll(step, "epoch", %{}).stream.cursor
    replaced = RuntimeTrace.apply_event(step, {:set_text, "answer", :answer, 1, "Привет 🐈"})
    assert RuntimePoll.poll(replaced, "epoch", cursor).stream.reset
    new_block = RuntimeTrace.apply_event(step, {:append_text, "answer", :answer, 2, "next"})
    assert RuntimePoll.poll(new_block, "epoch", cursor).stream.reset
    assert RuntimePoll.poll(step, "new epoch", cursor).stream.reset
  end

  test "a kind round trip invalidates the previous text prefix" do
    step = step()
    cursor = RuntimePoll.poll(step, "epoch", %{}).stream.cursor

    changed =
      step
      |> RuntimeTrace.apply_event({:set_media, "answer", :answer, 1, %{}})
      |> RuntimeTrace.apply_event(
        {:append_text, "answer", :answer, 1, "A completely different answer"}
      )

    assert RuntimePoll.poll(changed, "epoch", cursor).stream.reset
  end

  test "invalid offsets and addresses reset without crashing or slicing a UTF-8 character" do
    step = step()
    cursor = RuntimePoll.poll(step, "epoch", %{}).stream.cursor

    for offset <- [-1, 1, 100_000, "3", nil] do
      assert RuntimePoll.poll(step, "epoch", Map.put(cursor, "offset", offset)).stream.reset
    end

    assert RuntimePoll.poll(step, "epoch", Map.put(cursor, "item", "missing")).stream.reset
    assert RuntimePoll.poll(step, "epoch", Map.put(cursor, "id", "missing")).stream.reset
  end

  test "tool previews cannot be selected to bypass UI truncation" do
    step =
      RuntimeTrace.new_step(id: 1, sequence: 1)
      |> RuntimeTrace.apply_event(
        {:append_text, "tool", :tool_result, 1, String.duplicate("x", 100_000)}
      )

    reply = RuntimePoll.poll(step, "epoch", %{})
    assert reply.stream.targets == []
    content = step.items_by_key["tool"].contents_by_sequence[1]

    forged =
      Map.merge(reply.stream.cursor, %{
        "item" => "tool",
        "content" => 1,
        "id" => content.external_id,
        "generation" => 0,
        "offset" => 0
      })

    response = RuntimePoll.poll(step, "epoch", forged)
    assert response.stream.reset
    refute Map.has_key?(response.stream, :delta)
    assert hd(hd(response.step.items).contents).content_text_truncated
  end

  test "metadata changes need no content projection and raw provider data never escapes" do
    step = %{step() | raw_request: %{secret: true}, raw_response: %{secret: true}}
    first = RuntimePoll.poll(step, "epoch", %{})
    refute Map.has_key?(first.step, :raw_request)
    refute Map.has_key?(first.step, :raw_response)
    next = RuntimeTrace.apply_event(step, {:set_step_usage, %{output_tokens: 10}})
    reply = RuntimePoll.poll(next, "epoch", first.stream.cursor)
    assert reply.step.output_tokens == 10
    assert reply.step.items == []
    refute reply.stream.reset
  end
end
