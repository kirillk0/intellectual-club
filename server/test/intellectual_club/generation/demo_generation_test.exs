defmodule IntellectualClub.Generation.DemoGenerationTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor

  test "demo generation persists final content" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

    {:ok, _user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    {:ok, context} =
      GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

    message_id = context.message_id
    assert_receive {:done, ^message_id}, 1_000
    refute_receive {:done, ^message_id}, 300

    wait_until(fn ->
      message =
        Ash.get!(ChatMessage, context.message_id,
          actor: actor,
          load: [steps: [items: [:contents]]]
        )

      message.status == :done and
        String.contains?(message_answer_text(message), "You said: Hello")
    end)

    message =
      Ash.get!(ChatMessage, context.message_id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    assert length(message.steps) == 1
    step = hd(message.steps)
    assert step.sequence == 1
    assert length(step.items) == 1

    answer_item = Enum.find(step.items, &(&1.type == :answer))
    assert answer_item
    assert Enum.any?(answer_item.contents, &(&1.kind == :text))

    wait_until(fn ->
      GenerationSupervisor.get_generation_state(context.message_id) == :not_found
    end)
  end

  defp message_answer_text(message) do
    (message.steps || [])
    |> Enum.sort_by(& &1.sequence)
    |> Enum.flat_map(&(&1.items || []))
    |> Enum.filter(&(&1.type == :answer))
    |> Enum.flat_map(&(&1.contents || []))
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.map_join("", fn content -> content.content_text || "" end)
  end

  defp wait_until(fun, timeout_ms \\ 500) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_wait_until(fun, deadline)
      else
        flunk("Condition was not met before timeout")
      end
    end
  end
end
