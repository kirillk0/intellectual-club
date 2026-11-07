defmodule IntellectualClub.Chat.SubagentAttachmentsTest do
  use IntellectualClub.DataCase, async: false

  import IntellectualClub.SubagentFixtures, only: [persist_receipt: 5, tool_result_items: 2]

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask

  alias IntellectualClub.Chat.{ChatMessage, ChatMessageContent, ChatMessageItem, ChatMessageStep}

  alias IntellectualClub.Chat.{ContentFiles, Subagent, Threads}
  alias IntellectualClub.Files
  alias IntellectualClub.Generation.{Lease, Persistence, ToolResult}
  alias IntellectualClub.Llm.Providers.Common.ChatHistory
  alias IntellectualClub.Llm.Providers.Responses.HistoryInput
  alias IntellectualClub.Tools.Drivers.{NativeAgentManagement, NativeArtifactReader}
  alias IntellectualClub.Tools.{ExecutionContext, Executor}

  @payload "The control word is amber-orbit."

  for primitive <- [:fork, :spawn] do
    test "#{primitive} parent reads returned files without publishing attachments" do
      primitive = unquote(primitive)
      %{user: actor} = user_fixture()
      {parent, context} = parent_call!(actor, primitive)
      {child, message, step, reference} = child_answer!(actor, parent, primitive)
      file = file!("answer.txt", "text/plain", @payload)
      image = file!("answer.png", "image/png", png_1x1())
      attach!(actor, step, file, 2)
      attach!(actor, step, image, 3)
      attach!(actor, step, file, 4)

      assert {:error, :not_found} =
               ContentFiles.load_payload_for_execution(file.external_id, context)

      assert {:ok, snapshot} = Subagent.snapshot(reference, actor)
      assert snapshot.status == :completed

      assert Enum.map(snapshot.result.file_references, & &1.file_external_id) == [
               file.external_id,
               image.external_id
             ]

      assert snapshot.result.text =~ "file_id=#{file.external_id}"
      assert snapshot.result.text =~ "filename=\"answer.png\" mime_type=\"image/png\""
      refute snapshot.result.text =~ @payload

      result = Subagent.sync_execution_result_from_snapshot(snapshot, actor)
      assert result.file_references == snapshot.result.file_references
      assert result.artifacts == []
      assert result.media == []
      assert result.text =~ "file_id=#{image.external_id}"
      assert length(Regex.scan(~r/\[Subagent file/, result.text)) == 2
      before_write = load_message!(context.message_id, actor)
      assert tool_result_items(before_write, context.tool_call_item_id) == []
      assert artifact_file_ids(before_write) == []
      assert [call] = Persistence.list_missing_tool_calls!(context.step_id)
      assert call.item_id == context.tool_call_item_id

      assert {:error, :not_found} =
               ContentFiles.load_payload_for_execution(file.external_id, context)

      receipt = persist_parent_receipt!(context, call, result)
      replay = persist_parent_receipt!(context, call, result)
      assert receipt.item_id == replay.item_id
      assert receipt.responses_item == replay.responses_item
      assert receipt.result_raw == result.raw
      assert receipt.text == result.text
      assert Persistence.list_missing_tool_calls!(context.step_id) == []

      persisted = load_message!(context.message_id, actor)
      assert [item] = tool_result_items(persisted, context.tool_call_item_id)
      assert item.id == receipt.item_id
      assert artifact_file_ids(persisted) == []
      assert receipt.file_references == [file.external_id, image.external_id]
      assert replay.file_references == receipt.file_references

      for projection <- [
            HistoryInput.build_input_items([persisted], supports_image_input: true),
            ChatHistory.build_messages([persisted], supports_image_input: true)
          ] do
        encoded = Jason.encode!(projection)
        assert encoded =~ file.external_id
        assert encoded =~ image.external_id
        refute encoded =~ @payload
        refute encoded =~ "input_image"
        refute encoded =~ "image_url"
      end

      reader = tool!(actor, "native-artifact-reader")

      assert {:ok, {text, _raw}} =
               NativeArtifactReader.execute(
                 reader,
                 "read_file",
                 %{"file_id" => file.external_id},
                 context
               )

      assert text =~ @payload

      assert {:ok, {text, _raw}} =
               NativeArtifactReader.execute(
                 reader,
                 "search_file",
                 %{"file_id" => file.external_id, "regex" => "amber-orbit"},
                 context
               )

      assert text =~ "amber-orbit"

      assert {:ok, image_result} =
               NativeArtifactReader.execute(
                 reader,
                 "read_image",
                 %{"file_id" => image.external_id},
                 context
               )

      assert [%{file_external_id: image_id}] = image_result.media
      assert image_id == image.external_id

      assert {:ok, {_content, loaded, @payload}} =
               ContentFiles.load_payload_for_execution(file.external_id, context)

      assert loaded.id == file.id

      assert {:ok, {_content, _file, path}} =
               ContentFiles.load_path_for_execution(file.external_id, context)

      assert File.read!(path) == @payload

      fresh_context = %ExecutionContext{owner_id: actor.id, chat_id: parent.id}

      assert {:ok, {_content, _file, @payload}} =
               ContentFiles.load_payload_for_execution(file.external_id, fresh_context)

      unrelated = create_empty_chat!(actor)

      assert {:error, :not_found} =
               ContentFiles.load_payload_for_execution(file.external_id, %{
                 context
                 | chat_id: unrelated.id
               })

      %{user: other_actor} = user_fixture()
      assert {:error, _} = Subagent.snapshot(reference, other_actor)
      assert child.id == message.chat_id
    end

    test "#{primitive} background results retain file access without publishing attachments on repeated checks" do
      primitive = unquote(primitive)
      %{user: actor} = user_fixture()
      {parent, context} = parent_call!(actor, :check_background_task_status)
      {_child, _message, step, reference} = child_answer!(actor, parent, primitive)
      file = file!("background.txt", "text/plain", @payload)
      attach!(actor, step, file, 2)

      task =
        create!(
          BackgroundTask,
          :create,
          %{
            kind: to_string(primitive),
            adapter: to_string(primitive),
            status: :running,
            function_name: to_string(primitive),
            execution_context: %{},
            arguments: %{}
          },
          actor
        )

      assert {:ok, task} = BackgroundTasks.set_subagent_reference(task, reference)
      assert {:ok, first} = BackgroundTasks.snapshot(task.id, nil, actor.id)
      assert first["status"] == "completed"
      assert [%{"file_external_id" => file_id}] = first["result"]["file_references"]
      assert file_id == file.external_id

      assert {:ok, repeated} = BackgroundTasks.snapshot(task.id, first["next_cursor"], actor.id)
      assert repeated["progress"] == []
      assert repeated["result"]["file_references"] == first["result"]["file_references"]

      assert {:ok, result} =
               NativeAgentManagement.execute(
                 tool!(actor, "native-agent-management"),
                 "check_background_task_status",
                 %{"background_task_id" => task.id, "cursor" => first["next_cursor"]},
                 context
               )

      assert [%{file_external_id: ^file_id}] = result.file_references
      assert result.artifacts == []
      before_write = load_message!(context.message_id, actor)
      assert tool_result_items(before_write, context.tool_call_item_id) == []
      assert artifact_file_ids(before_write) == []

      assert {:error, :not_found} =
               ContentFiles.load_payload_for_execution(file.external_id, context)

      assert [call] = Persistence.list_missing_tool_calls!(context.step_id)
      assert call.name == "agent_management__check_background_task_status"
      receipt = persist_parent_receipt!(context, call, result)
      replay = persist_parent_receipt!(context, call, result)
      assert replay.item_id == receipt.item_id
      assert replay.responses_item == receipt.responses_item
      assert receipt.result_raw == result.raw
      assert Persistence.list_missing_tool_calls!(context.step_id) == []

      persisted = load_message!(context.message_id, actor)
      assert [item] = tool_result_items(persisted, context.tool_call_item_id)
      assert item.id == receipt.item_id
      assert artifact_file_ids(persisted) == []
      assert receipt.file_references == [file.external_id]

      for projection <- [
            HistoryInput.build_input_items([persisted], supports_image_input: true),
            ChatHistory.build_messages([persisted], supports_image_input: true)
          ] do
        encoded = Jason.encode!(projection)
        assert encoded =~ file.external_id
        refute encoded =~ @payload
      end

      assert {:ok, {_content, _file, @payload}} =
               ContentFiles.load_payload_for_execution(file.external_id, context)

      next_step = create_step!(actor, context.message_id, sequence: 2, status: :waiting_tools)

      next_call =
        opaque_item!(actor, next_step, :tool_call, 1, %{
          "call_id" => "repeat-status",
          "name" => "agent_management__check_background_task_status"
        })

      next_context = %{context | step_id: next_step.id, tool_call_item_id: next_call.id}

      assert {:ok, repeated_result} =
               NativeAgentManagement.execute(
                 tool!(actor, "native-agent-management"),
                 "check_background_task_status",
                 %{"background_task_id" => task.id, "cursor" => first["next_cursor"]},
                 next_context
               )

      assert [call] = Persistence.list_missing_tool_calls!(next_step.id)
      repeated_receipt = persist_parent_receipt!(next_context, call, repeated_result)
      assert repeated_receipt.file_references == [file.external_id]
      assert artifact_file_ids(load_message!(context.message_id, actor)) == []
    end
  end

  test "truncated results retain durable file access without publishing attachments" do
    %{user: actor} = user_fixture()
    {parent, context} = parent_call!(actor, :spawn)
    {_child, _message, step, reference} = child_answer!(actor, parent, :spawn)
    file = file!("result.txt", "text/plain", @payload)
    attach!(actor, step, file, 2)
    assert {:ok, snapshot} = Subagent.snapshot(reference, actor)

    result =
      snapshot
      |> Subagent.sync_execution_result_from_snapshot(actor)
      |> Executor.sanitize_execution_result()
      |> Executor.limit_execution_result(0)

    assert [call] = Persistence.list_missing_tool_calls!(context.step_id)
    receipt = persist_parent_receipt!(context, call, result)
    assert receipt.file_references == [file.external_id]
    assert artifact_file_ids(load_message!(context.message_id, actor)) == []

    assert {:ok, {_content, _file, @payload}} =
             ContentFiles.load_payload_for_execution(
               file.external_id,
               %ExecutionContext{owner_id: actor.id, chat_id: parent.id}
             )
  end

  test "compaction retains ordinary artifacts once and excludes checkpoint archives" do
    %{user: actor} = user_fixture()
    {parent, _context} = parent_call!(actor, :fork)
    {_child, message, copied_step, reference} = child_answer!(actor, parent, :fork)
    copied = file!("copied.txt", "text/plain", "old")
    viewed = file!("viewed.png", "image/png", png_1x1())
    first = file!("first.txt", "text/plain", "first")
    final = file!("final.txt", "text/plain", "final")
    attach!(actor, copied_step, copied, 2)
    marker = create_step!(actor, message, sequence: 2)

    opaque_item!(actor, marker, :tool_result, 1, %{
      "raw" => %{"fork_instruction" => %{"subagent" => true}}
    })

    attach!(actor, marker, copied, 2)
    own_step = create_step!(actor, message, sequence: 3)
    attach!(actor, own_step, viewed, 1, :tool_result)
    attach!(actor, own_step, first, 2)

    archive = file!("full_conversation.md", "text/markdown", "Archived dialogue")
    attach!(actor, own_step, archive, 3, :handoff_history)
    summary = create_item!(actor, own_step, type: :handoff_message, sequence: 4)
    create_content!(actor, summary, kind: :text, content_text: "Continue work")

    final_step = create_step!(actor, message, sequence: 4)
    attach!(actor, final_step, first, 1)
    attach!(actor, final_step, final, 2)

    assert {:ok, snapshot} = Subagent.snapshot(reference, actor)

    assert Enum.map(snapshot.result.file_references, & &1.file_external_id) == [
             first.external_id,
             final.external_id
           ]

    assert snapshot.result.raw["fork"]["final_message_id"] == message.id
    refute snapshot.result.text =~ copied.external_id
    refute snapshot.result.text =~ viewed.external_id
    refute snapshot.result.text =~ archive.external_id
  end

  test "an attachment-only answer returns its files without requiring answer text" do
    %{user: actor} = user_fixture()
    chat = create_empty_chat!(actor, %{subagent: true})

    message =
      create!(
        ChatMessage,
        :add_message,
        %{chat_id: chat.id, role: :assistant, status: :done},
        actor
      )

    step = create_step!(actor, message, sequence: 1)
    file = file!("only.txt", "text/plain", @payload)
    attach!(actor, step, file, 1)
    reference = %{primitive: :spawn, chat_id: chat.id, generation_message_id: message.id}
    assert {:ok, snapshot} = Subagent.snapshot(reference, actor)
    assert snapshot.progress == []
    assert snapshot.result.text =~ file.external_id

    assert [%{file_external_id: file_id}] =
             Subagent.sync_execution_result_from_snapshot(snapshot, actor).file_references

    assert file_id == file.external_id
  end

  defp parent_call!(actor, primitive) do
    chat = create_empty_chat!(actor)
    message = create!(ChatMessage, :create_generating_assistant, %{chat_id: chat.id}, actor)

    step =
      create!(
        ChatMessageStep,
        :create,
        %{chat_message_id: message.id, sequence: 1, status: :waiting_tools},
        actor
      )

    call_id = "call-#{System.unique_integer([:positive])}"
    name = "agent_management__#{primitive}"

    item =
      opaque_item!(actor, step, :tool_call, 1, %{
        "call_id" => call_id,
        "tool_call_id" => call_id,
        "name" => name,
        "raw" => %{
          "id" => call_id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => "{}"}
        }
      })

    {chat,
     %ExecutionContext{
       owner_id: actor.id,
       chat_id: chat.id,
       message_id: message.id,
       assistant_message_id: message.id,
       step_id: step.id,
       tool_call_item_id: item.id
     }}
  end

  defp child_answer!(actor, parent, primitive) do
    chat =
      create_empty_chat!(actor, %{
        parent_chat_id: parent.id,
        parent_relation_kind: primitive,
        subagent: true
      })

    {:ok, prompt} = Threads.add_message_to_end(chat, :user, "Work", actor: actor)
    {:ok, message} = Threads.add_message_to_end(chat, :assistant, "Done", actor: actor)
    message = load_message!(message.id, actor)

    reference = %{
      primitive: primitive,
      chat_id: chat.id,
      message_id: message.id,
      generation_message_id: message.id,
      prompt_message_id: prompt.id
    }

    {chat, message, hd(message.steps), reference}
  end

  defp attach!(actor, step, file, sequence, type \\ :artifact) do
    item =
      create!(
        ChatMessageItem,
        :create,
        item_attrs(actor, step, type, sequence),
        actor
      )

    create!(
      ChatMessageContent,
      :create,
      %{chat_message_item_id: item.id, sequence: 1, kind: :media, file_id: file.id},
      actor
    )
  end

  defp opaque_item!(actor, step, type, sequence, raw) do
    item =
      create!(
        ChatMessageItem,
        :create,
        item_attrs(actor, step, type, sequence),
        actor
      )

    create!(
      ChatMessageContent,
      :create,
      %{chat_message_item_id: item.id, sequence: 1, kind: :opaque, content_json: raw},
      actor
    )

    item
  end

  defp file!(name, mime, payload) do
    {:ok, file} = Files.create_from_binary(name, mime, payload)
    file
  end

  defp item_attrs(actor, step, :tool_result, sequence) do
    call =
      create!(
        ChatMessageItem,
        :create,
        %{
          chat_message_step_id: step.id,
          sequence: sequence + 1000,
          type: :tool_call
        },
        actor
      )

    %{
      chat_message_step_id: step.id,
      sequence: sequence,
      type: :tool_result,
      tool_call_item_id: call.id
    }
  end

  defp item_attrs(_actor, step, type, sequence) do
    %{chat_message_step_id: step.id, sequence: sequence, type: type}
  end

  defp load_message!(id, actor),
    do: Ash.get!(ChatMessage, id, actor: actor, load: [steps: [items: [contents: [:file]]]])

  defp artifact_file_ids(message) do
    message.steps
    |> Enum.sort_by(& &1.sequence)
    |> Enum.flat_map(& &1.items)
    |> Enum.sort_by(& &1.sequence)
    |> Enum.filter(&(&1.type == :artifact))
    |> Enum.flat_map(& &1.contents)
    |> Enum.map(& &1.file_id)
  end

  defp persist_parent_receipt!(context, call, result) do
    assert {:ok, lease} = Lease.acquire(context.message_id)

    try do
      assert {:ok, %ToolResult{} = receipt} =
               persist_receipt(lease, context.message_id, context.step_id, call, result)

      receipt
    after
      Lease.release(lease)
    end
  end

  defp tool!(actor, type) do
    create_tool_instance!(actor, type: type, name: "Attachment test", alias: "attachments")
  end
end
