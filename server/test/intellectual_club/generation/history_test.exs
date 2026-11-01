defmodule IntellectualClub.Generation.HistoryTest do
  @moduledoc """
  Canonical history handling in `IntellectualClub.Generation.History`: role
  boundary repair, trace projection helpers, history modes and the replay of
  reasoning captured by the provider stream reducers. Compaction checkpoints
  and their cumulative original-dialogue archives share this canonical boundary.
  """

  use IntellectualClub.DataCase, async: true

  import IntellectualClub.Chat.ForkFixtures

  alias IntellectualClub.Chat.{Chat, ForkHistory, HandoffRolloff, Threads}
  alias IntellectualClub.TokenCounter

  alias IntellectualClub.Generation.{History, RuntimeTrace}
  alias IntellectualClub.Llm.Providers

  @placeholder "<There is no user message yet, you should write first>"

  @blank_trace_user %{
    role: :user,
    steps: [
      %{
        sequence: 1,
        items: [
          %{
            sequence: 1,
            type: :input,
            contents: [%{sequence: 1, kind: :text, content_text: " \n\t "}]
          }
        ]
      }
    ]
  }

  @media_user %{
    role: :user,
    steps: [
      %{
        sequence: 1,
        items: [
          %{
            sequence: 1,
            type: :input,
            contents: [%{sequence: 1, kind: :media, external_id: "media-id"}]
          }
        ]
      }
    ]
  }

  @reasoning %{
    "type" => "reasoning",
    "id" => "rs_old",
    "summary" => [],
    "encrypted_content" => "reusable-secret"
  }

  describe "fix_role_alteration/1" do
    for {name, history, expected} <- [
          {"wraps assistant-only history in placeholders without merging messages",
           [%{role: :assistant, content: "First"}, %{role: :assistant, content: "Second"}],
           [
             %{role: :user, content: @placeholder},
             %{role: :assistant, content: "First"},
             %{role: :assistant, content: "Second"},
             %{role: :user, content: @placeholder}
           ]},
          {"keeps adjacent user messages separate",
           [%{role: :user, content: "First"}, %{role: :user, content: "Second"}],
           [%{role: :user, content: "First"}, %{role: :user, content: "Second"}]},
          {"replaces empty legacy and trace user messages",
           [
             %{role: :user, content: "  "},
             %{role: :assistant, content: "Answer"},
             @blank_trace_user
           ],
           [
             %{role: :user, content: @placeholder},
             %{role: :assistant, content: "Answer"},
             %{role: :user, content: @placeholder}
           ]},
          {"keeps a user message that contains canonical media", [@media_user], [@media_user]},
          {"creates one placeholder for an empty history", [],
           [%{role: :user, content: @placeholder}]}
        ] do
      test name do
        assert History.fix_role_alteration(unquote(Macro.escape(history))) ==
                 unquote(Macro.escape(expected))
      end
    end
  end

  describe "trace projection helpers" do
    test "normalizes legacy messages without provider projection" do
      assert History.normalize_message(%{role: :user, content: "Hello"}) == %{
               "role" => "user",
               "content" => "Hello"
             }

      assert History.normalize_message(%{
               "role" => "assistant",
               "content" => [%{"type" => "text"}]
             }) ==
               %{"role" => "assistant", "content" => [%{"type" => "text"}]}

      assert History.normalize_message(%{role: "user", content: "Wrong boundary"}) == nil
      assert History.normalize_message(%{role: :system, content: "Ignored"}) == nil
    end

    test "extracts ordered trace text and opaque payloads" do
      message = %{
        role: :assistant,
        steps: [
          %{
            sequence: 2,
            items: [
              %{
                sequence: 1,
                type: :answer,
                contents: [
                  %{sequence: 2, kind: :text, content_text: "second"},
                  %{sequence: 1, kind: :text, content_text: "first-"}
                ]
              }
            ]
          },
          %{
            sequence: 1,
            items: [
              %{
                sequence: 1,
                type: :tool_call,
                contents: [
                  %{sequence: 1, kind: :opaque, content_json: %{"name" => "tool"}}
                ]
              }
            ]
          }
        ]
      }

      assert History.trace_message?(message)
      assert History.message_role(message) == "assistant"
      assert History.project_text_for_item_type(message, :answer) == "first-second"

      [tool_item] =
        message
        |> History.steps()
        |> Enum.sort_by(&History.sort_seq/1)
        |> hd()
        |> History.items()

      assert History.item_type(tool_item) == :tool_call
      assert History.opaque_payloads(tool_item) == [%{"name" => "tool"}]
    end

    test "trace helpers consume canonical atom-valued domain maps" do
      assert History.item_type(:error) == :error
      assert History.item_type(:other) == :other
      assert History.item_type(%{type: "answer"}) == :other

      assert History.content_kind(:media) == :media
      assert History.content_kind(%{kind: "text"}) == :other

      refute History.trace_message?(%{"steps" => []})
      assert History.message_role(%{"role" => "assistant"}) == nil
    end
  end

  describe "after_compaction/1" do
    test "leaves histories without a complete same-step pair unchanged" do
      history = [
        %{role: :user, content: "Original"},
        %{
          role: :user,
          steps: [%{items: [item(:input, 1, "Standalone input", nil)]}]
        },
        %{
          role: :assistant,
          steps: [
            %{sequence: 1, items: [item(:handoff_history, 1, "Incomplete", nil)]},
            %{sequence: 2, items: [item(:handoff_message, 1, "Not a pair", nil)]},
            %{
              sequence: 3,
              items: [
                item(:handoff_history, 1, "Interrupted", nil),
                item(:answer, 2, "Answer", nil),
                item(:handoff_message, 3, "Unrelated", nil)
              ]
            }
          ]
        }
      ]

      assert History.after_compaction([]) == []
      assert History.after_compaction(history) == history
    end

    test "uses the last complete pair in sequence order and preserves its entire suffix" do
      archive = %{
        id: 20,
        chat_message_item_id: 2,
        sequence: 2,
        kind: :media,
        file_id: 10,
        external_id: "archive"
      }

      image = %{
        id: 21,
        chat_message_item_id: 1,
        sequence: 2,
        kind: :media,
        file_id: 11,
        external_id: "image"
      }

      history_item =
        item(:handoff_history, 4, "Current compacted history", nil)
        |> Map.put(:id, 2)
        |> Map.update!(:contents, &(&1 ++ [archive]))

      summary_item =
        item(:handoff_message, 5, "Current summary", nil)
        |> Map.put(:id, 1)
        |> Map.update!(:contents, &(&1 ++ [image]))

      suffix = item(:answer, 6, "Same-step suffix", nil)
      incomplete = item(:handoff_history, 7, "Unfinished newer checkpoint", nil)

      boundary = %{
        id: 1,
        sequence: 2,
        status: :canceled,
        raw_response: %{hidden: "Pre-boundary response"},
        items: [
          incomplete,
          summary_item,
          item(:handoff_message, 2, "Older same-step summary", nil),
          item(:handoff_history, 1, "Older same-step history", nil),
          suffix,
          history_item,
          item(:tool_result, 3, "Pre-boundary result", nil)
        ]
      }

      later_step = %{
        id: 0,
        sequence: 3,
        status: :done,
        items: [item(:answer, 1, "Later step", nil)]
      }

      earlier_step = %{
        id: 99,
        sequence: 1,
        status: :done,
        items: [
          item(:reasoning, 1, "Pre-boundary reasoning", @reasoning),
          item(:handoff_history, 2, "First compacted history", nil),
          item(:handoff_message, 3, "First summary", nil)
        ]
      }

      for status <- [:canceled, :error, :generating, :done] do
        message = %{
          id: 10,
          role: :assistant,
          status: status,
          llm_configuration_id: 4,
          steps: [later_step, boundary, earlier_step]
        }

        next_message = %{id: 3, role: :user, status: :done, content: "Next question"}

        assert [checkpoint, tail, ^next_message] =
                 History.after_compaction([
                   %{id: 100, role: :user, content: "Discarded original"},
                   message,
                   next_message
                 ])

        assert checkpoint.role == :user
        assert checkpoint.status == :done
        assert checkpoint.id == -summary_item.id
        assert checkpoint.id != tail.id
        assert checkpoint.compaction_checkpoint == true
        assert checkpoint.source_message_id == message.id
        assert [%{status: :done, items: [^history_item, ^summary_item]}] = checkpoint.steps
        refute Map.has_key?(hd(checkpoint.steps), :raw_response)
        assert Map.drop(tail, [:steps]) == Map.drop(message, [:steps])
        assert tail.steps == [%{boundary | items: [suffix, incomplete]}, later_step]

        assert [%{kind: :text, content_text: prompt}, projected_archive, projected_image] =
                 History.project_user_input_contents(checkpoint)

        assert prompt =~ "Current compacted history"
        assert prompt =~ "Current summary"
        refute prompt =~ "Older"
        assert Map.delete(projected_archive, :sequence) == Map.delete(archive, :sequence)
        assert Map.delete(projected_image, :sequence) == Map.delete(image, :sequence)

        assert History.after_compaction([checkpoint, tail, next_message]) ==
                 [checkpoint, tail, next_message]
      end
    end

    test "uses branch message order rather than global ids and supports a user checkpoint root" do
      old = %{
        id: 99,
        role: :assistant,
        steps: [
          %{
            items: [
              item(:handoff_history, 1, "Older history", nil),
              item(:handoff_message, 2, "Older summary", nil)
            ]
          }
        ]
      }

      latest = %{
        id: 1,
        role: :user,
        status: :done,
        steps: [
          %{
            items: [
              item(:handoff_history, 1, "Latest history", nil),
              item(:handoff_message, 2, "Latest summary", nil),
              item(:input, 3, "User suffix", nil)
            ]
          }
        ]
      }

      assert [checkpoint, suffix] = History.after_compaction([old, latest])
      assert checkpoint.id != latest.id
      assert checkpoint.source_message_id == latest.id
      assert checkpoint.compaction_checkpoint
      assert History.project_user_input_text(checkpoint) =~ "Latest summary"
      assert History.project_user_input_text(suffix) == "User suffix"
      assert [^checkpoint, ^suffix] = History.after_compaction([latest])
      assert [other_branch] = History.after_compaction([old])
      assert History.project_user_input_text(other_branch) =~ "Older summary"
    end

    test "checkpoint identity remains distinct and stable for maps without persisted ids" do
      message = %{
        role: :assistant,
        steps: [
          %{
            items: [
              item(:handoff_history, 1, "History", nil),
              item(:handoff_message, 2, "Summary", nil),
              item(:answer, 3, "Suffix", nil)
            ]
          }
        ]
      }

      assert [checkpoint, tail] = result = History.after_compaction([message])
      assert checkpoint.compaction_checkpoint
      assert checkpoint.source_message_id == nil
      assert checkpoint.id != Map.get(tail, :id)
      assert History.after_compaction(result) == result
      assert History.after_compaction([message]) == result
    end

    test "source after-response steering survives the cut without durable copies or replaying before-response steering" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      message = create_message!(actor, chat, llm_configuration_id: nil)
      step = create_step!(actor, message)

      create_opaque_item!(
        actor,
        step,
        "Already summarized steer",
        %{"placement" => "before_response"},
        type: :steering,
        sequence: 1
      )

      create_text_item!(actor, step, "Already summarized answer", sequence: 2)

      steer =
        create_opaque_item!(
          actor,
          step,
          "Carry original steer",
          %{"placement" => "after_response"},
          type: :steering,
          sequence: 3
        )

      create_text_item!(actor, step, "Compacted history", type: :handoff_history, sequence: 4)

      summary =
        create_text_item!(actor, step, "Checkpoint summary", type: :handoff_message, sequence: 5)

      original = Ash.load!(message, [steps: [items: [:contents]]], actor: actor)
      assert [checkpoint, tail] = compacted = History.after_compaction([original])
      assert checkpoint.id == -summary.id
      assert checkpoint.source_message_id == original.id
      assert [%{items: [carried]}] = tail.steps
      assert carried.id == steer.id
      assert carried == Enum.find(hd(original.steps).items, &(&1.id == steer.id))
      assert History.after_compaction(compacted) == compacted

      adapters = [
        Providers.Responses,
        Providers.ResponsesWss,
        Providers.GoogleInteractions,
        Providers.AnthropicMessages,
        Providers.OpenRouterChatCompletion,
        Providers.NvidiaBuildChatCompletion
      ]

      for mode <- [:chat, :agent, :full], adapter <- adapters do
        context = %{
          history: [checkpoint],
          model_name: "test",
          parameters: %{},
          tools: [],
          system_prompt: ""
        }

        initial = adapter.build_initial_request(context)
        fresh = adapter.inject_steering(initial.raw_request, [carried], context)

        replay =
          adapter.build_initial_request(%{
            context
            | history: History.for_mode(compacted, mode, 4)
          })

        assert replay.request_snapshot.model_input == fresh.request_snapshot.model_input,
               inspect({mode, adapter})

        input = Jason.encode!(replay.request_snapshot.model_input)
        assert length(String.split(input, "Carry original steer")) == 2
        refute input =~ "Already summarized"
      end

      suffix = create_text_item!(actor, step, "Same-step suffix", sequence: 6)
      later_step = create_step!(actor, message, sequence: 2)

      queued =
        create_opaque_item!(
          actor,
          later_step,
          "New queued steer",
          %{"placement" => "before_response"},
          type: :steering,
          sequence: 1
        )

      later_answer = create_text_item!(actor, later_step, "Later answer", sequence: 2)
      stored = Ash.load!(message, [steps: [items: [:contents]]], actor: actor)
      assert [^checkpoint, tail] = with_suffix = History.after_compaction([stored])

      assert Enum.map(tail.steps, fn step -> Enum.map(step.items, & &1.id) end) == [
               [steer.id, suffix.id],
               [queued.id, later_answer.id]
             ]

      for mode <- [:chat, :agent, :full], adapter <- adapters do
        input =
          adapter.build_initial_request(%{
            history: History.for_mode(with_suffix, mode, 4),
            model_name: "test"
          })
          |> Map.fetch!(:request_snapshot)
          |> Map.fetch!(:model_input)
          |> Jason.encode!()

        texts = [
          "Checkpoint summary",
          "Carry original steer",
          "Same-step suffix",
          "New queued steer",
          "Later answer"
        ]

        for text <- texts, do: assert(length(String.split(input, text)) == 2)
        positions = Enum.map(texts, &(:binary.match(input, &1) |> elem(0)))
        assert positions == Enum.sort(positions)
        refute input =~ "Already summarized"
      end

      reloaded = Ash.load!(message, [steps: [items: [:contents]]], actor: actor)
      assert ordered_trace_records(reloaded) == ordered_trace_records(stored)
    end

    test "linked fork boundaries ignore later source checkpoints but keep earlier step checkpoints" do
      %{user: actor} = user_fixture()
      source = create_fork_source!(actor, previous_step?: true)
      child = create_fork_child!(actor, source)

      create_text_item!(actor, source.step, "PRIVATE POST-FORK HISTORY",
        type: :handoff_history,
        sequence: 100
      )

      create_text_item!(actor, source.step, "PRIVATE POST-FORK SUMMARY",
        type: :handoff_message,
        sequence: 101
      )

      assert {:ok, branch} = ForkHistory.effective_branch(child, nil, actor)
      assert History.after_compaction(branch) == branch

      create_text_item!(actor, source.previous, "Earlier compacted history",
        type: :handoff_history,
        sequence: 2
      )

      create_text_item!(actor, source.previous, "Earlier summary",
        type: :handoff_message,
        sequence: 3
      )

      assert {:ok, branch} = ForkHistory.effective_branch(child, nil, actor)
      assert [checkpoint, boundary] = History.after_compaction(branch)
      assert History.project_user_input_text(checkpoint) =~ "Earlier summary"
      assert [%{id: step_id}] = boundary.steps
      assert step_id == source.step.id

      for mode <- [:chat, :agent, :full] do
        input =
          [checkpoint, boundary]
          |> History.for_mode(mode, 4)
          |> then(&Providers.Responses.build_initial_request(%{history: &1}))
          |> Map.fetch!(:raw_request)
          |> Jason.encode!()

        assert input =~ "Earlier compacted history"
        assert input =~ "FORK CONTROL MESSAGE"
        refute input =~ "PRIVATE POST-FORK"
      end
    end

    test "all provider modes start with checkpoint input and never replay the discarded step" do
      message = Enum.at(fixture(@reasoning), 1)
      old_step = hd(message.steps)

      checkpoint_step = %{
        sequence: 2,
        status: :done,
        items: [
          item(:tool_result, 1, "Just-before-checkpoint result", nil),
          item(:handoff_history, 2, "Compacted context", nil),
          item(:handoff_message, 3, "Continue here", nil),
          item(:answer, 4, "New answer", nil)
        ]
      }

      message = %{message | steps: [old_step, checkpoint_step]}

      for mode <- [:chat, :agent, :full],
          adapter <- [
            Providers.Responses,
            Providers.ResponsesWss,
            Providers.GoogleInteractions,
            Providers.AnthropicMessages,
            Providers.OpenRouterChatCompletion,
            Providers.NvidiaBuildChatCompletion
          ] do
        history = [message] |> History.after_compaction() |> History.for_mode(mode, 4)

        input =
          adapter.build_initial_request(%{history: history, model_name: "test"})
          |> Map.fetch!(:request_snapshot)
          |> Map.fetch!(:model_input)
          |> Jason.encode!()

        assert input =~ "Compacted context"
        assert input =~ "Continue here"
        assert input =~ "New answer"

        for discarded <- [
              "tool-return-value",
              "reusable-secret",
              "Edited answer",
              "User steering",
              "Just-before-checkpoint result"
            ] do
          refute input =~ discarded, inspect({mode, adapter, discarded})
        end
      end
    end
  end

  describe "cumulative compaction archives" do
    test "repeated in-message checkpoints archive original items once through the generating source" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      file = create_file!(filename: "original-report.md", payload: "Original artifact")
      old_archive = create_file!(filename: "full_conversation.md", payload: "OLD ARCHIVE")
      {:ok, root} = Threads.add_message_to_end(chat, :user, "Original request", actor: actor)
      message = create_message!(actor, chat, parent_id: root.id, status: :generating)
      step = create_step!(actor, message, status: :done)
      create_text_item!(actor, step, "Original answer", type: :answer, sequence: 1)
      create_text_item!(actor, step, "Original steering", type: :steering, sequence: 2)
      artifact = create_item!(actor, step, type: :artifact, sequence: 3)
      create_content!(actor, artifact, kind: :media, file_id: file.id)

      for sequence <- [4, 6] do
        copy =
          create_text_item!(actor, step, "COPIED HISTORY",
            type: :handoff_history,
            sequence: sequence
          )

        create_content!(actor, copy, kind: :media, file_id: old_archive.id, sequence: 2)

        create_text_item!(actor, step, "COPIED SUMMARY",
          type: :handoff_message,
          sequence: sequence + 1
        )
      end

      create_text_item!(actor, step, "Same-step continuation", type: :answer, sequence: 8)
      later_step = create_step!(actor, message, sequence: 2, status: :waiting_tools)
      create_text_item!(actor, later_step, "In-progress answer", type: :answer)
      call = create_item!(actor, later_step, type: :tool_call, sequence: 2)

      create_text_item!(actor, later_step, "Not dialogue",
        type: :tool_result,
        sequence: 3,
        tool_call_item_id: call.id
      )

      create_text_item!(actor, later_step, "NOT ORIGINAL SUMMARY",
        type: :handoff_summary,
        sequence: 4
      )

      create_text_item!(actor, later_step, "Not reasoning", type: :reasoning, sequence: 5)

      {:ok, _later} =
        Threads.add_message(chat, :user, "After source boundary",
          actor: actor,
          parent_id: message.id
        )

      {:ok, _sibling} =
        Threads.add_message(chat, :assistant, "Other branch", actor: actor, parent_id: root.id)

      assert {:ok, result} =
               HandoffRolloff.build(chat, actor, "New summary", source_message_id: message.id)

      assert result.strategy == :full
      assert result.artifact.filename == "full_conversation.md"

      assert Enum.map(result.history, & &1.role) == [
               :user,
               :assistant,
               :user,
               :assistant,
               :assistant,
               :assistant
             ]

      assert Enum.map(result.history, & &1.text) |> Enum.take(3) == [
               "Original request",
               "Original answer",
               "Original steering"
             ]

      assert List.last(result.history).text == "In-progress answer"
      archive = result.artifact.payload

      for original <- [
            "Original request",
            "Original answer",
            "Original steering",
            "Same-step continuation",
            "In-progress answer",
            "file_id=#{file.external_id}"
          ] do
        assert length(String.split(archive, original)) == 2
      end

      for excluded <- [
            "COPIED",
            "OLD ARCHIVE",
            "NOT ORIGINAL SUMMARY",
            "Not dialogue",
            "Not reasoning",
            "After source boundary",
            "Other branch",
            "file_id=#{old_archive.external_id}",
            "full_conversation.md"
          ] do
        refute archive =~ excluded
      end
    end

    test "user checkpoints do not duplicate earlier dialogue and an explicitly selected branch controls the archive" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      {:ok, root} = Threads.add_message_to_end(chat, :user, "Original task", actor: actor)

      {:ok, answer} =
        Threads.add_message_to_end(chat, :assistant, "Answer before manual checkpoint",
          actor: actor
        )

      {:ok, checkpoint} =
        Threads.add_message_with_items(
          chat,
          :user,
          [
            %{
              type: :handoff_history,
              contents: [%{kind: :text, content_text: "COPIED ORIGINAL TASK"}]
            },
            %{
              type: :handoff_message,
              contents: [%{kind: :text, content_text: "OLD CHECKPOINT SUMMARY"}]
            },
            %{type: :input, contents: [%{kind: :text, content_text: "New user input"}]}
          ],
          actor: actor,
          parent_id: answer.id
        )

      {:ok, sibling} =
        Threads.add_message(chat, :assistant, "Sibling answer", actor: actor, parent_id: root.id)

      assert {:ok, compacted} =
               HandoffRolloff.build(chat, actor, "Next summary", source_message_id: checkpoint.id)

      assert Enum.map(compacted.history, & &1.text) == [
               "Original task",
               "Answer before manual checkpoint",
               "New user input"
             ]

      assert {:ok, other} =
               HandoffRolloff.build(chat, actor, "Other summary", source_message_id: sibling.id)

      assert Enum.map(other.history, & &1.text) == ["Original task", "Sibling answer"]

      assert {:error, :message_not_found} =
               HandoffRolloff.build(chat, actor, "Invalid target", source_message_id: -1)
    end

    test "the default archive follows the current selected branch even with a stale chat record" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      {:ok, root} = Threads.add_message_to_end(chat, :user, "Root task", actor: actor)

      {:ok, _old_branch} =
        Threads.add_message_to_end(chat, :assistant, "OLD BRANCH", actor: actor)

      {:ok, selected} =
        Threads.add_message(chat, :assistant, "Selected answer", actor: actor, parent_id: root.id)

      assert chat.last_message_id == nil
      assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == selected.id
      assert {:ok, result} = HandoffRolloff.build(chat, actor, "Summary")
      assert Enum.map(result.history, & &1.text) == ["Root task", "Selected answer"]
      refute result.artifact.payload =~ "OLD BRANCH"
    end

    test "standalone checkpoint roots expand only the original seed with original roles" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      old_archive = create_file!(filename: "full_conversation.md", payload: "OLD FILE")

      {:ok, root} =
        Threads.add_message_with_items(
          chat,
          :user,
          [
            %{
              type: :handoff_history,
              contents: [
                %{
                  kind: :text,
                  content_text: "Original request",
                  content_json: %{"role" => "user"}
                },
                %{
                  kind: :text,
                  content_text: "Original answer",
                  content_json: %{"role" => "assistant"}
                },
                %{kind: :media, file_id: old_archive.id}
              ]
            },
            %{
              type: :handoff_message,
              contents: [%{kind: :text, content_text: "Initial seed summary"}]
            },
            %{type: :handoff_history, contents: [%{kind: :text, content_text: "COPIED SEED"}]},
            %{type: :handoff_message, contents: [%{kind: :text, content_text: "COPIED SUMMARY"}]}
          ],
          actor: actor
        )

      assert {:ok, result} =
               HandoffRolloff.build(chat, actor, "New summary", source_message_id: root.id)

      assert Enum.map(result.history, &{&1.role, &1.text}) == [
               {:user, "Original request"},
               {:assistant, "Original answer"},
               {:user, "Initial seed summary"}
             ]

      refute result.artifact.payload =~ "COPIED"
      refute result.artifact.payload =~ "full_conversation.md"
    end

    test "standalone normalized input does not read unrelated chat history" do
      %{user: actor} = user_fixture()
      unrelated = create_empty_chat!(actor)

      {:ok, _other} =
        Threads.add_message_to_end(unrelated, :user, "UNRELATED HISTORY", actor: actor)

      standalone = create_empty_chat!(actor)

      {:ok, seed} =
        Threads.add_message_to_end(standalone, :user, "Stored standalone context", actor: actor)

      {:ok, answer} =
        Threads.add_message_to_end(standalone, :assistant, "Local answer", actor: actor)

      for target <- [seed, answer] do
        assert {:ok, result} =
                 HandoffRolloff.build(standalone, actor, "Summary", source_message_id: target.id)

        assert hd(result.history).text == "Stored standalone context"

        assert String.contains?(result.artifact.payload, "Local answer") ==
                 (target.id == answer.id)

        refute result.artifact.payload =~ "UNRELATED HISTORY"
      end
    end

    test "branches without an original prefix preserve their initial checkpoint seed only once" do
      %{user: actor} = user_fixture()

      for role <- [:user, :assistant] do
        chat = create_empty_chat!(actor)

        {:ok, seed} =
          Threads.add_message_with_items(
            chat,
            role,
            [
              %{type: :handoff_history, contents: [%{kind: :text, content_text: "Seed history"}]},
              %{type: :handoff_message, contents: [%{kind: :text, content_text: "Seed summary"}]}
            ],
            actor: actor
          )

        {:ok, branch} =
          Threads.add_message_with_items(
            chat,
            :user,
            [
              %{
                type: :handoff_history,
                contents: [%{kind: :text, content_text: "COPIED SEED HISTORY"}]
              },
              %{
                type: :handoff_message,
                contents: [%{kind: :text, content_text: "COPIED SEED SUMMARY"}]
              },
              %{type: :input, contents: [%{kind: :text, content_text: "Branch input"}]}
            ],
            actor: actor,
            parent_id: seed.id
          )

        {:ok, _sibling} =
          Threads.add_message(chat, :assistant, "OTHER BRANCH", actor: actor, parent_id: seed.id)

        assert {:ok, result} =
                 HandoffRolloff.build(chat, actor, "Summary", source_message_id: branch.id)

        assert Enum.map(result.history, & &1.text) == [
                 "Seed history",
                 "Seed summary",
                 "Branch input"
               ]

        refute result.artifact.payload =~ "COPIED"
        refute result.artifact.payload =~ "OTHER BRANCH"
      end
    end

    test "linked forks use only their authorized effective prefix at the fixed response cutoff" do
      %{user: actor} = user_fixture()
      source = create_fork_source!(actor, previous_step?: true)
      child = create_fork_child!(actor, source)

      create_text_item!(actor, source.step, "PRIVATE ARTIFACT AFTER FORK",
        sequence: 100,
        type: :artifact
      )

      later_step = create_step!(actor, source.message, sequence: 3)
      create_text_item!(actor, later_step, "PRIVATE LATER STEP")

      {:ok, _later} =
        Threads.add_message(source.chat, :user, "PRIVATE LATER MESSAGE",
          actor: actor,
          parent_id: source.message.id
        )

      {:ok, local} =
        Threads.add_message_to_end(child, :assistant, "Local fork answer", actor: actor)

      for target <- [nil, local.id] do
        assert {:ok, result} =
                 HandoffRolloff.build(child, actor, "Fork summary", source_message_id: target)

        assert result.artifact.payload =~ "Root question"
        assert result.artifact.payload =~ "Earlier completed step"
        assert result.artifact.payload =~ "Parent completed response"
        assert result.artifact.payload =~ "FORK CONTROL MESSAGE"

        assert String.contains?(result.artifact.payload, "Local fork answer") ==
                 is_integer(target)

        refute result.artifact.payload =~ "PRIVATE"
      end
    end

    test "sharing only a linked child does not authorize its source archive" do
      %{user: actor} = user_fixture()
      %{user: reader} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [actor, reader]})

      source =
        create_fork_source!(actor,
          chat_attrs: %{
            bot_id: create_bot!(actor).id,
            llm_configuration_id: create_configuration!(actor).id
          }
        )

      child = create_fork_child!(actor, source)
      share_chat!(actor, child, group)
      assert Ash.get!(Chat, child.id, actor: reader).id == child.id
      assert {:error, :fork_context_unavailable} = HandoffRolloff.build(child, reader, "Summary")
    end

    test "hard rolloff preserves the chronological suffix and the complete original archive" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)

      original =
        for index <- 1..130 do
          %{
            kind: :text,
            content_text: "entry-#{index} " <> String.duplicate("wide-context ", 90),
            content_json: %{"role" => "user"}
          }
        end

      {:ok, root} =
        Threads.add_message_with_items(
          chat,
          :user,
          [%{type: :handoff_history, contents: original}],
          actor: actor
        )

      assert {:ok, result} =
               HandoffRolloff.build(chat, actor, "Summary", source_message_id: root.id)

      assert result.strategy == :hard_middle_out
      assert result.token_count <= HandoffRolloff.budget_tokens()
      assert [%{text: first}, %{kind: :omission} | tail] = result.history
      assert first =~ "entry-1 "

      indices =
        Enum.map(tail, fn entry ->
          [_, index] = Regex.run(~r/^entry-(\d+) /, entry.text)
          String.to_integer(index)
        end)

      assert length(indices) > 1
      assert indices == Enum.to_list(hd(indices)..130)

      for %{content_text: text} <- original do
        assert length(String.split(result.artifact.payload, String.trim(text))) == 2
      end

      refute result.artifact.payload =~ "truncated"
      refute result.artifact.payload =~ "omitted"
    end

    test "provider truncation keeps the complete supplied display summary and original archive" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      {:ok, root} = Threads.add_message_to_end(chat, :user, "Original task", actor: actor)
      summary = "BEGIN SUMMARY " <> String.duplicate("large-summary ", 8_000) <> " SUMMARY END"

      assert {:ok, result} =
               HandoffRolloff.build(chat, actor, summary, source_message_id: root.id)

      assert result.strategy == :hard_middle_out
      assert result.handoff_message == summary
      prompt = HandoffRolloff.render_prompt(result.history, result.handoff_message)
      assert prompt =~ "BEGIN SUMMARY"
      assert prompt =~ "[truncated to"
      refute prompt =~ "SUMMARY END"
      assert result.token_count == TokenCounter.estimate(prompt)
      assert result.token_count <= HandoffRolloff.budget_tokens()
      assert result.artifact.payload =~ "Original task"
      refute result.artifact.payload =~ "truncated"
    end
  end

  describe "for_mode/3" do
    test "every adapter replays only eligible opaque reasoning and keeps canonical answers" do
      adapters = [
        {Providers.Responses, @reasoning},
        {Providers.ResponsesWss, @reasoning},
        {Providers.GoogleInteractions,
         %{"google_interaction_step" => %{"type" => "thought", "signature" => "reusable-secret"}}},
        {Providers.AnthropicMessages,
         %{
           "anthropic_content_block" => %{
             "type" => "thinking",
             "thinking" => "Native thinking",
             "signature" => "reusable-secret"
           }
         }},
        {Providers.OpenRouterChatCompletion,
         %{
           "chat_completion_reasoning" => %{
             "reasoning_details" => [
               %{"type" => "reasoning.encrypted", "data" => "reusable-secret", "index" => 0}
             ]
           }
         }},
        {Providers.NvidiaBuildChatCompletion,
         %{"chat_completion_reasoning" => %{"reasoning_content" => "reusable-secret"}}}
      ]

      for {adapter, opaque} <- adapters,
          {mode, configuration_id, reasoning?, tools?} <- [
            {:agent, 4, false, true},
            {:chat, 4, false, false},
            {:full, 4, true, true},
            {:full, 5, false, true},
            {:full, nil, false, true}
          ] do
        history = fixture(opaque) |> History.for_mode(mode, configuration_id)

        result =
          adapter.build_initial_request(%{
            history: history,
            model_name: "test-model",
            parameters: %{},
            tools: [],
            system_prompt: ""
          })

        input = Jason.encode!(result.request_snapshot.model_input)
        assert String.contains?(input, "reusable-secret") == reasoning?, inspect({adapter, mode})
        assert String.contains?(input, "tool-return-value") == tools?, inspect({adapter, mode})
        assert String.contains?(input, "Edited answer")
        assert String.contains?(input, "User steering")
        assert String.contains?(input, "turn_aborted") == (mode != :chat)
        refute String.contains?(input, "stale-raw-response")
        refute String.contains?(input, "display-only-reasoning")
      end
    end

    test "full mode selects reasoning per message and never treats missing configuration IDs as compatible" do
      message = Enum.at(fixture(@reasoning), 1)
      history = Enum.map([4, 5, 4, nil], &Map.put(message, :llm_configuration_id, &1))

      for {id, expected} <- [
            {4, [true, false, true, false]},
            {5, [false, true, false, false]},
            {nil, [false, false, false, false]}
          ] do
        actual =
          history
          |> History.for_mode(:full, id)
          |> Enum.map(fn entry ->
            entry.steps |> Enum.flat_map(& &1.items) |> Enum.any?(&(&1.type == :reasoning))
          end)

        assert actual == expected
      end
    end

    test "full mode omits text-only reasoning even if the raw response has reusable data" do
      history = fixture(nil) |> History.for_mode(:full, 4)
      input = Providers.Responses.build_initial_request(%{history: history}).raw_request
      refute inspect(input) =~ "display-only-reasoning"
      refute inspect(input) =~ "stale-raw-response"
      refute Enum.any?(input["input"], &(&1["type"] == "reasoning"))
    end

    test "chat mode removes empty assistant turns before role repair and keeps user media" do
      user = %{
        role: :user,
        steps: [
          %{
            items: [
              item(:input, 1, "", nil)
              |> Map.put(
                :contents,
                [%{kind: :media, sequence: 1, file_id: 12}]
              )
            ]
          }
        ]
      }

      assistant = %{
        role: :assistant,
        steps: [%{items: [item(:reasoning, 1, "Hidden", @reasoning)]}]
      }

      assert [^user] =
               [user, assistant] |> History.for_mode(:chat, 4) |> History.fix_role_alteration()
    end
  end

  describe "reasoning round trip through the provider stream reducers" do
    test "Responses HTTP and WSS replay terminal encrypted reasoning that has no text" do
      first = %{
        "id" => "rs_1",
        "type" => "reasoning",
        "summary" => [],
        "encrypted_content" => "encrypted-first"
      }

      second = %{
        "id" => "rs_2",
        "type" => "reasoning",
        "summary" => [],
        "encrypted_content" => "encrypted-second"
      }

      events = [
        %{
          "type" => "response.output_item.added",
          "output_index" => 0,
          "item" => Map.delete(first, "encrypted_content")
        },
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => first},
        %{
          "type" => "response.completed",
          "response" => %{"output" => [Map.delete(first, "encrypted_content"), second]}
        }
      ]

      stored = persist_events(Providers.Responses.StreamEvents, events)
      assert Enum.map(stored.items, & &1.type) == [:reasoning, :reasoning]

      assert Enum.all?(stored.items, fn item ->
               Enum.all?(item.contents, &(&1.kind == :opaque))
             end)

      for provider <- [Providers.Responses, Providers.ResponsesWss] do
        input =
          provider.build_initial_request(%{history: full_history(stored), model_name: "test"}).raw_request[
            "input"
          ]

        assert Enum.map(input, & &1["encrypted_content"]) == [
                 "encrypted-first",
                 "encrypted-second"
               ]
      end
    end

    test "Google Interactions replays signed thoughts, including a terminal-only block" do
      thought = %{
        "type" => "thought",
        "signature" => "signature-one",
        "summary" => [%{"type" => "text", "text" => "Summary"}]
      }

      hidden = %{"type" => "thought", "signature" => "signature-two"}

      events = [
        %{"event_type" => "step.start", "index" => 0, "step" => %{"type" => "thought"}},
        %{
          "event_type" => "step.delta",
          "index" => 0,
          "delta" => %{
            "type" => "thought_summary",
            "content" => %{"type" => "text", "text" => "Sum"}
          }
        },
        %{
          "event_type" => "step.delta",
          "index" => 0,
          "delta" => %{
            "type" => "thought_summary",
            "content" => %{"type" => "text", "text" => "mary"}
          }
        },
        %{
          "event_type" => "step.delta",
          "index" => 0,
          "delta" => %{"type" => "thought_signature", "signature" => "signature-one"}
        },
        %{"event_type" => "step.stop", "index" => 0},
        %{
          "event_type" => "interaction.completed",
          "interaction" => %{"status" => "completed", "steps" => [thought, hidden]}
        }
      ]

      stored = persist_events(Providers.GoogleInteractions.StreamEvents, events)
      assert Enum.map(stored.items, & &1.type) == [:reasoning, :reasoning]
      assert [%{kind: :opaque}] = List.last(stored.items).contents

      request =
        Providers.GoogleInteractions.build_initial_request(%{
          history: full_history(stored),
          model_name: "test"
        }).raw_request

      assert request["input"] == [thought, hidden]
    end
  end

  # Relationship load order is unspecified; compare complete records in sequence order.
  defp ordered_trace_records(message) do
    steps =
      Enum.map(message.steps, fn step ->
        items =
          Enum.map(step.items, fn item ->
            %{item | contents: Enum.sort_by(item.contents, &{&1.sequence, &1.id})}
          end)

        %{step | items: Enum.sort_by(items, &{&1.sequence, &1.id})}
      end)

    %{message | steps: Enum.sort_by(steps, &{&1.sequence, &1.id})}
  end

  defp fixture(opaque) do
    [
      %{role: :user, content: "Question"},
      %{
        role: :assistant,
        llm_configuration_id: 4,
        steps: [
          %{
            sequence: 1,
            raw_response: %{"reasoning" => "stale-raw-response"},
            items: [
              item(:reasoning, 1, "display-only-reasoning", opaque),
              item(:answer, 2, "Edited answer", nil),
              item(:tool_call, 3, "", %{
                "name" => "lookup",
                "call_id" => "call_1",
                "arguments" => %{}
              }),
              item(:tool_result, 4, "tool-return-value", %{"call_id" => "call_1"}),
              item(:steering, 5, "User steering", nil)
            ]
          }
        ]
      },
      %{role: :user, history_marker: :turn_aborted, content: "<turn_aborted>"},
      %{role: :user, content: "Next question"}
    ]
  end

  defp item(type, sequence, text, opaque) do
    contents = [%{kind: :text, sequence: 1, content_text: text}]

    contents =
      if opaque,
        do: contents ++ [%{kind: :opaque, sequence: 10_000, content_json: opaque}],
        else: contents

    %{type: type, sequence: sequence, contents: contents}
  end

  defp full_history(stored) do
    History.for_mode(
      [%{role: :assistant, llm_configuration_id: 1, steps: [Map.delete(stored, :raw_response)]}],
      :full,
      1
    )
  end

  defp persist_events(reducer, events) do
    emit = fn event -> send(self(), {:event, event}) end
    Enum.reduce(events, reducer.new_state(), &reducer.handle_event(&2, &1, %{}, emit))
    collect(RuntimeTrace.new_step()) |> RuntimeTrace.persistable()
  end

  defp collect(step) do
    receive do
      {:event, {:trace, event}} -> collect(RuntimeTrace.apply_event(step, event))
      {:event, _event} -> collect(step)
    after
      0 -> step
    end
  end
end
