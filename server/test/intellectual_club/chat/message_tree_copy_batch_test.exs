defmodule IntellectualClub.Chat.MessageTreeCopyBatchTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.{
    Chat,
    ChatMessage,
    ChatMessageContent,
    ChatMessageItem,
    ChatMessageStep,
    MessageTreeCopy
  }

  alias IntellectualClub.SqlCapture

  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Generation.StepRequests
  alias IntellectualClub.Llm.{LlmConfiguration, LlmProvider}
  alias IntellectualClub.Sharing

  require Ash.Query

  test "trace inserts are batched per message and repeated item sequences stay within their steps" do
    %{user: actor} = user_fixture()

    first =
      source_message!(actor,
        status: :generating,
        step_statuses: [:done, :waiting_provider, :waiting_tools]
      )

    second =
      source_message!(actor,
        chat_id: first.chat_id,
        parent_id: first.id,
        status: :error
      )

    target = create_empty_chat!(actor)

    {{:ok, copied_ids}, %{queries: queries}} =
      SqlCapture.measure(fn ->
        Repo.transaction(fn ->
          MessageTreeCopy.copy_messages!(
            [reverse_trace(first), reverse_trace(second)],
            target,
            actor
          )
        end)
      end)

    # Each message needs one ordinary-item batch, one result batch and one content batch.
    assert insert_count(queries, "chat_message_items") == 4
    assert insert_count(queries, "chat_message_contents") == 2

    [copied_first, copied_second] = messages_for_chat(target.id, actor)
    assert copied_ids == %{first.id => copied_first.id, second.id => copied_second.id}
    assert copied_second.parent_id == copied_first.id
    assert copied_first.status == :canceled
    assert copied_first.error_detail == "Copied from an active generation."
    assert copied_second.status == :error
    assert copied_second.error_detail == second.error_detail
    assert copied_first.token_count == first.token_count
    assert trace_signature(copied_first) == trace_signature(first)
    assert trace_signature(copied_second) == trace_signature(second)

    assert Enum.map(ordered(copied_first.steps), & &1.status) == [:done, :canceled, :canceled]

    assert Enum.map(ordered(loaded_message!(first.id, actor).steps), & &1.status) ==
             [:done, :waiting_provider, :waiting_tools]

    assert loaded_message!(first.id, actor).status == :generating
    assert trace_signature(loaded_message!(first.id, actor)) == trace_signature(first)
  end

  test "step and sequence mapping survives the 250-row item and content batch boundaries" do
    %{user: actor} = user_fixture()
    # Only calls and results get a second (opaque) content: 256 items and 264 contents.
    source =
      source_message!(actor,
        steps: 2,
        ordinary_count: 126,
        opaque?: &(&1.type in [:tool_call, :tool_result])
      )

    target = create_empty_chat!(actor)

    {{:ok, _copied_ids}, %{queries: queries}} =
      SqlCapture.measure(fn ->
        Repo.transaction(fn ->
          MessageTreeCopy.copy_messages!([reverse_trace(source)], target, actor)
        end)
      end)

    # 252 ordinary items and four results (3 batches) and 264 contents (2 batches) cross
    # independent batch boundaries.
    assert insert_count(queries, "chat_message_items") == 3
    assert insert_count(queries, "chat_message_contents") == 2
    [copied] = messages_for_chat(target.id, actor)
    assert trace_signature(copied) == trace_signature(source)
  end

  test "tool-result recovery remains step-local and drops only results without a copied call" do
    %{user: actor} = user_fixture()
    source = source_message!(actor)
    [first, second, third] = ordered(source.steps)
    foreign_call = Enum.find(first.items, &(&1.type == :tool_call and &1.sequence == 1))

    second =
      %{
        second
        | items:
            Enum.map(second.items, fn
              %{type: :tool_result, sequence: 5} = item ->
                %{item | tool_call_item_id: foreign_call.id}

              %{type: :tool_result} = item ->
                %{item | tool_call_item_id: nil}

              item ->
                item
            end)
      }

    third = %{third | items: Enum.reject(third.items, &(&1.type == :tool_call))}
    snapshot = %{source | steps: [third, second, first]}
    target = create_empty_chat!(actor)

    assert {:ok, _} =
             Repo.transaction(fn -> MessageTreeCopy.copy_messages!([snapshot], target, actor) end)

    [copied] = messages_for_chat(target.id, actor)
    [copied_first, copied_second, copied_third] = ordered(copied.steps)

    # An explicit same-step link wins over a more recent call; stale links fall back locally.
    assert tool_links(copied_first) == [{5, 1}, {6, 2}]
    assert tool_links(copied_second) == [{5, 2}, {6, 2}]
    assert tool_links(copied_third) == []
    assert Enum.map(ordered(copied_third.items), & &1.type) == [:answer, :error]
    assert trace_signature(loaded_message!(source.id, actor)) == trace_signature(source)
  end

  test "an explicit link to a non-call still fails Ash validation and rolls back every step" do
    %{user: actor} = user_fixture()
    source = source_message!(actor, steps: 2)

    snapshot =
      update_last_step(source, fn step ->
        answer = Enum.find(step.items, &(&1.type == :answer))

        %{
          step
          | items:
              Enum.map(step.items, fn
                %{type: :tool_result} = item -> %{item | tool_call_item_id: answer.id}
                item -> item
              end)
        }
      end)

    target = create_empty_chat!(actor)
    before_ids = copy_record_ids(actor)

    assert {:error, error} =
             Repo.transaction(fn -> MessageTreeCopy.copy_messages!([snapshot], target, actor) end)

    assert inspect(error) =~ "tool_call_item_id"

    assert copy_record_ids(actor) == before_ids
    assert Ash.get!(Chat, target.id, actor: actor).last_message_id == nil
    assert trace_signature(loaded_message!(source.id, actor)) == trace_signature(source)
  end

  test "attachments are independently duplicated for each copied content across steps" do
    %{user: actor} = user_fixture()
    {:ok, file} = Files.create_from_binary("trace.txt", "text/plain", "immutable attachment")
    source = source_message!(actor, steps: 2, file_id: file.id)
    target = create_empty_chat!(actor)

    assert {:ok, _} =
             Repo.transaction(fn -> MessageTreeCopy.copy_messages!([source], target, actor) end)

    [copied] = messages_for_chat(target.id, actor)
    copied_file_ids = media_file_ids(copied)
    assert length(copied_file_ids) == 2
    assert length(Enum.uniq(copied_file_ids)) == 2
    refute file.id in copied_file_ids

    for id <- copied_file_ids do
      duplicate = Ash.get!(StoredFile, id, actor: actor)
      assert duplicate.sha256 == file.sha256
      assert duplicate.size_bytes == file.size_bytes
      assert duplicate.external_id != file.external_id
    end

    assert media_file_ids(loaded_message!(source.id, actor)) == [file.id, file.id]
    assert trace_signature(copied) == trace_signature(source)
  end

  test "a late content error rolls back steps, item batches and duplicated attachment rows" do
    %{user: actor} = user_fixture()
    {:ok, file} = Files.create_from_binary("rollback.txt", "text/plain", "rollback attachment")
    source = source_message!(actor, steps: 2, file_id: file.id)

    snapshot =
      update_last_step(source, fn step ->
        %{
          step
          | items:
              Enum.map(step.items, fn
                %{type: :tool_result, sequence: 6} = item ->
                  %{item | contents: Enum.map(item.contents, &%{&1 | kind: :invalid_kind})}

                item ->
                  item
              end)
        }
      end)

    target = create_empty_chat!(actor)
    before_ids = copy_record_ids(actor)

    assert {:error, error} =
             Repo.transaction(fn -> MessageTreeCopy.copy_messages!([snapshot], target, actor) end)

    assert inspect(error) =~ "kind"

    assert copy_record_ids(actor) == before_ids
    assert Ash.get!(Chat, target.id, actor: actor).last_message_id == nil
    assert media_file_ids(loaded_message!(source.id, actor)) == [file.id, file.id]
    assert trace_signature(loaded_message!(source.id, actor)) == trace_signature(source)
  end

  test "configuration selection is copy-scoped and does not replace create authorization" do
    %{user: owner} = user_fixture()
    %{user: actor} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, actor]})

    provider =
      create!(
        LlmProvider,
        :create,
        %{name: "Copy provider", type: :demo, auth_method: :api_key},
        owner
      )

    configuration =
      create!(
        LlmConfiguration,
        :create,
        %{provider_id: provider.id, model_name: "demo", context_length: 2048},
        owner
      )

    assert {:ok, _} =
             Sharing.replace_llm_configuration_share_state(configuration.id, [group.id], owner)

    first = source_message!(actor, configuration_id: configuration.id, steps: 1)

    second =
      source_message!(actor,
        chat_id: first.chat_id,
        parent_id: first.id,
        configuration_id: configuration.id,
        steps: 1
      )

    snapshot = [first, second]
    target = create_empty_chat!(actor)

    {{:ok, _}, %{queries: queries}} =
      SqlCapture.measure(fn ->
        Repo.transaction(fn -> MessageTreeCopy.copy_messages!(snapshot, target, actor) end)
      end)

    # One authorized selection plus the unchanged relationship checks on both message creates.
    assert select_count(queries, "llm_configurations") == 3

    assert Enum.map(messages_for_chat(target.id, actor), & &1.llm_configuration_id) ==
             [configuration.id, configuration.id]

    # The source chat belongs to the recipient, so revoking the configuration
    # share does not revoke read access to the source messages themselves.
    assert {:ok, _} = Sharing.replace_llm_configuration_share_state(configuration.id, [], owner)
    denied_target = create_empty_chat!(actor)

    assert {:ok, _} =
             Repo.transaction(fn ->
               MessageTreeCopy.copy_messages!(snapshot, denied_target, actor)
             end)

    assert Enum.map(messages_for_chat(denied_target.id, actor), & &1.llm_configuration_id) == [
             nil,
             nil
           ]

    assert {:ok, _} =
             Sharing.replace_llm_configuration_share_state(configuration.id, [group.id], owner)

    restored_target = create_empty_chat!(actor)

    assert {:ok, _} =
             Repo.transaction(fn ->
               MessageTreeCopy.copy_messages!(snapshot, restored_target, actor)
             end)

    assert Enum.map(messages_for_chat(restored_target.id, actor), & &1.llm_configuration_id) ==
             [configuration.id, configuration.id]
  end

  test "supplied source and step structs cannot replace Ash read authorization" do
    %{user: actor} = user_fixture()
    %{user: stranger} = user_fixture()
    source = source_message!(actor, steps: 1)
    foreign = source_message!(stranger, steps: 1)
    target = create_empty_chat!(actor)
    forged_message = %{foreign | owner_id: actor.id}

    assert_raise RuntimeError, ~r/Copy source is unavailable/, fn ->
      Repo.transaction(fn -> MessageTreeCopy.copy_messages!([forged_message], target, actor) end)
    end

    [foreign_step] = foreign.steps
    forged_step = %{foreign_step | owner_id: actor.id, chat_message_id: source.id}

    error =
      assert_raise StepRequests.Error, fn ->
        Repo.transaction(fn ->
          MessageTreeCopy.copy_messages!([%{source | steps: [forged_step]}], target, actor)
        end)
      end

    assert error.reason == :not_found
    assert messages_for_chat(target.id, actor) == []
    assert trace_signature(loaded_message!(source.id, actor)) == trace_signature(source)
    assert trace_signature(loaded_message!(foreign.id, stranger)) == trace_signature(foreign)
  end

  test "a forged target owner cannot bypass the message create authorization" do
    %{user: actor} = user_fixture()
    %{user: stranger} = user_fixture()
    source = source_message!(actor, steps: 1)
    target = create_empty_chat!(stranger)

    assert {:error, error} =
             Repo.transaction(fn ->
               MessageTreeCopy.copy_messages!([source], %{target | owner_id: actor.id}, actor)
             end)

    assert inspect(error) =~ "chat_id"

    assert messages_for_chat(target.id, stranger) == []
    assert trace_signature(loaded_message!(source.id, actor)) == trace_signature(source)
  end

  defp source_message!(actor, opts \\ []) do
    chat_id = Keyword.get_lazy(opts, :chat_id, fn -> create_empty_chat!(actor).id end)

    message =
      create!(
        ChatMessage,
        :add_message,
        %{
          chat_id: chat_id,
          parent_id: opts[:parent_id],
          llm_configuration_id: opts[:configuration_id],
          role: :assistant,
          status: Keyword.get(opts, :status, :done),
          error_detail: "source diagnostic",
          token_count: 37
        },
        actor
      )

    steps =
      for sequence <- 1..Keyword.get(opts, :steps, 3) do
        create!(
          ChatMessageStep,
          :create,
          %{
            chat_message_id: message.id,
            sequence: sequence,
            status: Enum.at(Keyword.get(opts, :step_statuses, []), sequence - 1, :done),
            raw_request: %{"step" => sequence},
            raw_response: %{"output" => sequence},
            response_final: true,
            input_tokens: sequence,
            output_tokens: sequence + 1,
            cached_input_tokens: 2,
            reasoning_tokens: 3,
            cost: 0.25
          },
          actor
        )
      end

    ordinary_count = Keyword.get(opts, :ordinary_count, 4)

    ordinary =
      for step <- steps, sequence <- 1..ordinary_count do
        %{
          chat_message_step_id: step.id,
          sequence: sequence,
          type:
            cond do
              sequence <= 2 -> :tool_call
              sequence == 4 -> :error
              true -> :answer
            end
        }
      end
      |> create_batch!(ChatMessageItem, actor)

    calls = Map.new(ordinary, &{{&1.chat_message_step_id, &1.sequence}, &1.id})

    results =
      for step <- steps, sequence <- 1..2 do
        %{
          chat_message_step_id: step.id,
          sequence: ordinary_count + sequence,
          type: :tool_result,
          tool_call_item_id: Map.fetch!(calls, {step.id, sequence})
        }
      end
      |> create_batch!(ChatMessageItem, actor)

    opaque? = Keyword.get(opts, :opaque?, fn _item -> true end)

    Enum.flat_map(ordinary ++ results, fn item ->
      text = %{
        chat_message_item_id: item.id,
        sequence: 1,
        kind: :text,
        content_text: "  step #{item.chat_message_step_id}, item #{item.sequence}\n"
      }

      opaque = %{
        chat_message_item_id: item.id,
        sequence: 3,
        kind: :opaque,
        content_json: %{"source_step" => item.chat_message_step_id, "source_item" => item.id}
      }

      contents = if opaque?.(item), do: [text, opaque], else: [text]

      if opts[:file_id] && item.type == :answer do
        contents ++
          [
            %{
              chat_message_item_id: item.id,
              sequence: 5,
              kind: :media,
              file_id: opts[:file_id]
            }
          ]
      else
        contents
      end
    end)
    |> create_batch!(ChatMessageContent, actor)

    loaded_message!(message.id, actor)
  end

  defp create_batch!(attrs, resource, actor) do
    assert %Ash.BulkResult{status: :success, records: records} =
             Ash.bulk_create(attrs, resource, :create,
               actor: actor,
               return_records?: true,
               return_errors?: true,
               transaction: :all,
               batch_size: 250
             )

    records
  end

  defp loaded_message!(id, actor) do
    ChatMessage
    |> Ash.get!(id, actor: actor, load: trace_load_spec())
  end

  defp messages_for_chat(chat_id, actor) do
    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(trace_load_spec())
    |> Ash.read!(actor: actor)
  end

  defp trace_load_spec do
    Enum.map(MessageTreeCopy.load_spec(), fn
      {:steps, fields} -> {:steps, [:raw_request | fields]}
      field -> field
    end)
  end

  defp reverse_trace(message) do
    %{
      message
      | steps:
          Enum.map(Enum.reverse(message.steps), fn step ->
            %{
              step
              | items:
                  Enum.map(Enum.reverse(step.items), fn item ->
                    %{item | contents: Enum.reverse(item.contents)}
                  end)
            }
          end)
    }
  end

  defp update_last_step(message, fun) do
    %{message | steps: message.steps |> ordered() |> List.update_at(-1, fun)}
  end

  defp trace_signature(message) do
    Enum.map(ordered(message.steps), fn step ->
      step
      |> Map.take([
        :sequence,
        :raw_request,
        :request_mode,
        :request_hash,
        :raw_response,
        :response_final,
        :input_tokens,
        :output_tokens,
        :cached_input_tokens,
        :reasoning_tokens,
        :cost,
        :first_token_at,
        :last_token_at
      ])
      |> Map.put(
        :items,
        Enum.map(ordered(step.items), fn item ->
          %{
            sequence: item.sequence,
            type: item.type,
            tool_call_sequence: linked_call_sequence(step, item),
            contents:
              Enum.map(
                ordered(item.contents),
                &Map.take(
                  &1,
                  [:sequence, :kind, :content_text, :content_json]
                )
              )
          }
        end)
      )
    end)
  end

  defp linked_call_sequence(step, %{tool_call_item_id: id}) when is_integer(id) do
    call = Enum.find(step.items, &(&1.id == id))
    call.sequence
  end

  defp linked_call_sequence(_step, _item), do: nil

  defp tool_links(step) do
    step.items
    |> ordered()
    |> Enum.filter(&(&1.type == :tool_result))
    |> Enum.map(&{&1.sequence, linked_call_sequence(step, &1)})
  end

  defp media_file_ids(message) do
    for step <- ordered(message.steps),
        item <- ordered(step.items),
        content <- ordered(item.contents),
        content.kind == :media,
        do: content.file_id
  end

  defp copy_record_ids(actor) do
    Map.new(
      [ChatMessage, ChatMessageStep, ChatMessageItem, ChatMessageContent, StoredFile],
      fn resource ->
        ids =
          resource |> Ash.Query.select([:id]) |> Ash.read!(actor: actor) |> MapSet.new(& &1.id)

        {resource, ids}
      end
    )
  end

  defp ordered(records), do: Enum.sort_by(records, & &1.sequence)

  defp insert_count(queries, table) do
    Enum.count(queries, &(&1.source == table and String.starts_with?(&1.sql, "INSERT")))
  end

  defp select_count(queries, table) do
    Enum.count(queries, &(&1.source == table and String.starts_with?(&1.sql, "SELECT")))
  end
end
