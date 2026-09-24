defmodule IntellectualClub.Chat.LinkedForkFilesTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.{
    Chat,
    ChatMessage,
    ChatMessageContent,
    ChatMessageItem,
    ChatMessageStep,
    ChatMessageStepRequestFile,
    ContentFiles
  }

  alias IntellectualClub.Files
  alias IntellectualClub.Generation.RequestImages
  alias IntellectualClub.Tools.ExecutionContext

  require Ash.Query

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6lq8AAAAASUVORK5CYII="
       )
  @invalid_fallback "[Image omitted: attached file could not be validated as an image.]"

  test "an empty linked fork reads only files in its inherited provider-response prefix" do
    fixture = fork_fixture!()
    context = context(fixture.child, fixture.actor)

    assert ContentFiles.handoff_chat_scope_ids(fixture.child.id, fixture.actor.id) == [
             fixture.child.id
           ]

    assert [] ==
             ChatMessage
             |> Ash.Query.filter(chat_id == ^fixture.child.id)
             |> Ash.read!(actor: fixture.actor)

    assert_readable(context, fixture.allowed)
    assert_denied(context, fixture.denied)
  end

  test "nested forks retain each inherited prefix without admitting either parent's future" do
    fixture = fork_fixture!()
    nested = nested_fork!(fixture)
    context = context(nested.chat, fixture.actor)

    assert_readable(context, fixture.allowed ++ [nested.input])
    assert_denied(context, fixture.denied ++ [nested.future])

    step = followup_step!(fixture.actor, nested.chat)

    assert_materialized(
      step,
      fixture.allowed ++ [nested.input],
      fixture.denied ++ [nested.future]
    )
  end

  test "handoff descendants preserve a linked fork's restricted inherited file scope" do
    fixture = fork_fixture!()

    handoff =
      chat!(fixture.actor, %{parent_chat_id: fixture.child.id, parent_relation_kind: :handoff})

    nested_handoff =
      chat!(fixture.actor, %{parent_chat_id: handoff.id, parent_relation_kind: :handoff})

    own_step = followup_step!(fixture.actor, fixture.child)
    own = attach!(fixture.actor, own_step, :artifact, 1, "own-fork-artifact")

    assert ContentFiles.handoff_chat_scope_ids(nested_handoff.id, fixture.actor.id) == [
             nested_handoff.id,
             handoff.id,
             fixture.child.id
           ]

    assert_readable(context(nested_handoff, fixture.actor), fixture.allowed ++ [own])
    assert_denied(context(nested_handoff, fixture.actor), fixture.denied)

    # Handoff itself still grants access to its whole owned source chat.
    ordinary_handoff =
      chat!(fixture.actor, %{parent_chat_id: fixture.parent.id, parent_relation_kind: :handoff})

    assert_readable(context(ordinary_handoff, fixture.actor), [fixture.future, fixture.result])
  end

  test "canonical followup images do not reuse future parent request-file bindings" do
    fixture = fork_fixture!()
    request = image_request([fixture.future])

    assert {:ok, ^request} =
             RequestImages.materialize_and_persist(request, fixture.future_step.id)

    assert [_binding] = bindings(fixture.future_step)

    step = followup_step!(fixture.actor, fixture.child)
    assert bindings(step) == []
    assert_materialized(step, fixture.allowed, fixture.denied)
  end

  test "cloning only the source request bindings leaves canonical prefix files available later" do
    fixture = fork_fixture!()
    [source_image | other_images] = fixture.allowed
    request = image_request([source_image])

    assert {:ok, ^request} = RequestImages.materialize_and_persist(request, fixture.boundary.id)
    first_step = followup_step!(fixture.actor, fixture.child)
    assert :ok = RequestImages.clone_bindings(fixture.boundary.id, first_step.id)

    assert [source_binding] = bindings(fixture.boundary)
    assert [child_binding] = bindings(first_step)
    refute source_binding.file_id == child_binding.file_id
    assert child_binding.source_file_external_id == source_image.file.external_id
    assert {:ok, wire_request} = RequestImages.hydrate(request, first_step.id)
    assert [wire_image] = image_blocks(wire_request)
    assert wire_image["image_url"] == "data:image/png;base64," <> Base.encode64(@png)

    # These older canonical images were not pinned on the fork's source step.
    next_step = step!(fixture.actor, first_step.chat_message_id, 2)
    assert_materialized(next_step, other_images, fixture.denied)
  end

  test "another owner cannot read a linked fork's inherited or own files" do
    fixture = fork_fixture!()
    %{user: other_actor} = user_fixture()
    own_step = followup_step!(fixture.actor, fixture.child)
    own = attach!(fixture.actor, own_step, :artifact, 1, "owned-local-file")

    assert_denied(context(fixture.child, other_actor), fixture.allowed ++ [own])
  end

  test "an unavailable fork projection fails closed instead of opening its parent chat" do
    fixture = fork_fixture!()

    fixture.boundary
    |> Ash.Changeset.for_update(:update, %{response_final: false}, actor: fixture.actor)
    |> Ash.update!(actor: fixture.actor)

    assert_denied(context(fixture.child, fixture.actor), fixture.allowed)
    assert_materialized(followup_step!(fixture.actor, fixture.child), [], fixture.allowed)
  end

  test "handoff ancestry traversal terminates on a cycle" do
    %{user: actor} = user_fixture()
    first = chat!(actor)
    second = chat!(actor, %{parent_chat_id: first.id, parent_relation_kind: :handoff})

    first
    |> Ash.Changeset.for_update(
      :update,
      %{parent_chat_id: second.id, parent_relation_kind: :handoff},
      actor: actor
    )
    |> Ash.update!(actor: actor)

    assert ContentFiles.handoff_chat_scope_ids(second.id, actor.id) == [second.id, first.id]

    assert {:error, :not_found} =
             ContentFiles.load_payload_for_execution(Ecto.UUID.generate(), context(second, actor))
  end

  defp fork_fixture! do
    %{user: actor} = user_fixture()
    parent = chat!(actor)
    input_message = message!(actor, parent, %{role: :user})
    input_step = step!(actor, input_message.id, 1)
    input = attach!(actor, input_step, :input, 1, "prefix-input")
    sibling_message = message!(actor, parent, %{parent_id: input_message.id})
    sibling_step = step!(actor, sibling_message.id, 1)
    sibling = attach!(actor, sibling_step, :artifact, 1, "sibling-message")
    message = message!(actor, parent, %{parent_id: input_message.id})
    earlier_step = step!(actor, message.id, 1)
    earlier_call = call!(actor, earlier_step, 1)

    earlier_result =
      attach!(actor, earlier_step, :tool_result, 2, "prefix-result",
        tool_call_item_id: earlier_call.id
      )

    earlier_artifact = attach!(actor, earlier_step, :artifact, 3, "prefix-artifact")
    boundary = step!(actor, message.id, 2)
    before_response = attach!(actor, boundary, :steering, 1, "before-response")
    placement!(actor, before_response.item, "before_response")
    response = attach!(actor, boundary, :answer, 2, "provider-response")
    selected_call = call!(actor, boundary, 3)
    sibling_call = call!(actor, boundary, 4)
    child = fork!(actor, parent, boundary, selected_call)

    result =
      attach!(actor, boundary, :tool_result, 5, "boundary-result",
        tool_call_item_id: selected_call.id
      )

    sibling_result =
      attach!(actor, boundary, :tool_result, 6, "boundary-sibling-result",
        tool_call_item_id: sibling_call.id
      )

    artifact = attach!(actor, boundary, :artifact, 7, "boundary-artifact")
    after_response = attach!(actor, boundary, :steering, 8, "after-response")
    placement!(actor, after_response.item, "after_response")
    future_step = step!(actor, message.id, 3)
    future = attach!(actor, future_step, :artifact, 1, "future-step")
    later_message = message!(actor, parent, %{role: :user, parent_id: message.id})
    later_step = step!(actor, later_message.id, 1)
    later = attach!(actor, later_step, :input, 1, "future-message")
    sibling_chat = fork!(actor, parent, boundary, sibling_call)
    sibling_local_step = followup_step!(actor, sibling_chat)
    sibling_local = attach!(actor, sibling_local_step, :artifact, 1, "sibling-fork")

    %{
      actor: actor,
      parent: parent,
      child: child,
      boundary: boundary,
      future_step: future_step,
      future: future,
      result: result,
      allowed: [input, earlier_result, earlier_artifact, before_response, response],
      denied: [
        result,
        sibling_result,
        artifact,
        after_response,
        future,
        later,
        sibling,
        sibling_local
      ]
    }
  end

  defp nested_fork!(fixture) do
    actor = fixture.actor
    input_message = message!(actor, fixture.child, %{role: :user})
    input_step = step!(actor, input_message.id, 1)
    input = attach!(actor, input_step, :input, 1, "nested-prefix")
    message = message!(actor, fixture.child, %{parent_id: input_message.id})
    boundary = step!(actor, message.id, 1)
    call = call!(actor, boundary, 1)
    chat = fork!(actor, fixture.child, boundary, call)
    future_step = step!(actor, message.id, 2)
    future = attach!(actor, future_step, :artifact, 1, "nested-future")
    %{chat: chat, input: input, future: future}
  end

  defp assert_readable(context, attachments) do
    for %{file: file, content: content} <- attachments do
      assert {:ok, {loaded_content, loaded_file, @png}} =
               ContentFiles.load_payload_for_execution(file.external_id, context)

      assert loaded_content.id == content.id
      assert loaded_file.id == file.id

      assert {:ok, {loaded_content, loaded_file, path}} =
               ContentFiles.load_path_for_execution(file.external_id, context)

      assert loaded_content.id == content.id
      assert loaded_file.id == file.id
      assert File.read!(path) == @png
    end
  end

  defp assert_denied(context, attachments) do
    for %{file: file} <- attachments do
      assert {:error, :not_found} =
               ContentFiles.load_payload_for_execution(file.external_id, context)

      assert {:error, :not_found} =
               ContentFiles.load_path_for_execution(file.external_id, context)
    end
  end

  defp assert_materialized(step, allowed, denied) do
    assert {:ok, compact} =
             RequestImages.materialize_and_persist(image_request(allowed ++ denied), step.id)

    blocks = image_blocks(compact)
    assert Enum.take(blocks, length(allowed)) == image_blocks(image_request(allowed))

    assert Enum.drop(blocks, length(allowed)) ==
             Enum.map(denied, fn _ -> %{"type" => "input_text", "text" => @invalid_fallback} end)

    assert MapSet.new(bindings(step), &to_string(&1.source_file_external_id)) ==
             MapSet.new(allowed, &to_string(&1.file.external_id))

    assert {:ok, wire} = RequestImages.hydrate(compact, step.id)

    for block <- Enum.take(image_blocks(wire), length(allowed)) do
      assert block["image_url"] == "data:image/png;base64," <> Base.encode64(@png)
    end
  end

  defp context(chat, actor) do
    %ExecutionContext{owner_id: actor.id, chat_id: chat.id, available_file_external_ids: []}
  end

  defp chat!(actor, attrs \\ %{}) do
    create!(Chat, :create_empty, attrs, actor)
  end

  defp fork!(actor, parent, boundary, call) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      %{
        parent_chat_id: parent.id,
        parent_message_id: boundary.chat_message_id,
        parent_tool_call_item_id: call.id,
        parent_relation_kind: :fork,
        subagent: true
      },
      actor: actor
    )
    |> Ash.Changeset.force_change_attributes(%{
      fork_source_step_id: boundary.id,
      fork_task: "Read only the inherited files."
    })
    |> Ash.create!(actor: actor)
  end

  defp message!(actor, chat, attrs \\ %{}) do
    create!(
      ChatMessage,
      :add_message,
      Map.merge(%{chat_id: chat.id, role: :assistant, status: :done}, attrs),
      actor
    )
  end

  defp step!(actor, message_id, sequence) do
    create!(
      ChatMessageStep,
      :create,
      %{chat_message_id: message_id, sequence: sequence, status: :done, response_final: true},
      actor
    )
  end

  defp followup_step!(actor, chat) do
    message = message!(actor, chat)
    step!(actor, message.id, 1)
  end

  defp call!(actor, step, sequence) do
    item =
      create!(
        ChatMessageItem,
        :create,
        %{chat_message_step_id: step.id, sequence: sequence, type: :tool_call},
        actor
      )

    create!(
      ChatMessageContent,
      :create,
      %{
        chat_message_item_id: item.id,
        sequence: 1,
        kind: :opaque,
        content_json: %{
          "call_id" => "call_#{item.id}",
          "name" => "agent_management__fork",
          "arguments" => %{"task" => "Read only the inherited files."}
        }
      },
      actor
    )

    item
  end

  defp attach!(actor, step, type, sequence, name, opts \\ []) do
    {:ok, file} = Files.create_from_binary(name <> ".png", "image/png", @png)

    item =
      create!(
        ChatMessageItem,
        :create,
        %{
          chat_message_step_id: step.id,
          sequence: sequence,
          type: type,
          tool_call_item_id: Keyword.get(opts, :tool_call_item_id)
        },
        actor
      )

    content =
      create!(
        ChatMessageContent,
        :create,
        %{chat_message_item_id: item.id, sequence: 1, kind: :media, file_id: file.id},
        actor
      )

    %{file: file, content: content, item: item}
  end

  defp placement!(actor, item, placement) do
    create!(
      ChatMessageContent,
      :create,
      %{
        chat_message_item_id: item.id,
        sequence: 2,
        kind: :opaque,
        content_json: %{"placement" => placement}
      },
      actor
    )
  end

  defp image_request(attachments) do
    %{
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" =>
            Enum.map(attachments, fn %{file: file} ->
              %{
                "type" => "input_image",
                "image_url" => RequestImages.marker(to_string(file.external_id), "image/png")
              }
            end)
        }
      ]
    }
  end

  defp image_blocks(request), do: request["input"] |> hd() |> Map.fetch!("content")

  defp bindings(step) do
    ChatMessageStepRequestFile
    |> Ash.Query.filter(chat_message_step_id == ^step.id)
    |> Ash.read!(authorize?: false)
  end

  defp create!(resource, action, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(action, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end
end
