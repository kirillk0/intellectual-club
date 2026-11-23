defmodule IntellectualClub.Tools.NativeKnowledgeLibraryTest do
  use IntellectualClub.DataCase, async: false
  alias IntellectualClub.Accounts.UserKnowledgeBlock
  alias IntellectualClub.Bots.BotKnowledgeBlock
  alias IntellectualClub.Chat.{ChatKnowledgeBlock, ContentFiles}
  alias IntellectualClub.Files
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeBlockFile
  alias IntellectualClub.Knowledge.KnowledgeBlockShare
  alias IntellectualClub.Knowledge.KnowledgeBlockTag
  alias IntellectualClub.Llm.LlmConfigurationKnowledgeBlock
  alias IntellectualClub.Secrets.{KnowledgeBlockSecret, Secret}
  alias IntellectualClub.Tools.BindingResolver
  alias IntellectualClub.Tools.Drivers.NativeKnowledgeLibrary
  alias IntellectualClub.Tools.Executor
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ToolInstance

  test "lists, reads, and searches owner blocks from a configured tag subtree" do
    %{user: owner} = user_fixture()

    root = create_knowledge_tag!(owner, name: "Library")
    child = create_knowledge_tag!(owner, name: "Child", parent_id: root.id)
    other = create_knowledge_tag!(owner, name: "Other")

    root_block =
      create_knowledge_block!(owner,
        name: "Root Block",
        version: "v1",
        content: "Visible root text\n//// hidden root note"
      )

    attached_file =
      create_attachment!(owner, root_block, "root.txt", "text/plain", "root file payload")

    disabled_file =
      create_attachment!(
        owner,
        root_block,
        "disabled.txt",
        "text/plain",
        "disabled file payload",
        false
      )

    child_block =
      create_knowledge_block!(owner,
        name: "Child Block",
        version: "v2",
        content: "Visible child text"
      )

    other_block =
      create_knowledge_block!(owner, name: "Other Block", version: "v3", content: "Other text")

    duplicate_a =
      create_knowledge_block!(owner,
        name: "Duplicate",
        version: "a",
        content: "First duplicate text"
      )

    duplicate_b =
      create_knowledge_block!(owner,
        name: "Duplicate",
        version: "b",
        content: "Second duplicate text"
      )

    attach_tag!(owner, root_block, root)
    attach_tag!(owner, child_block, child)
    attach_tag!(owner, other_block, other)
    attach_tag!(owner, duplicate_a, root)
    attach_tag!(owner, duplicate_b, root)

    tool = create_library_tool!(owner, root.id, %{"chunk_size_tokens" => 4})

    assert {:ok, {list_text, list_raw}} =
             NativeKnowledgeLibrary.execute(tool, "list_blocks", %{"max_results" => 10})

    assert list_text =~ "Root Block"
    assert list_text =~ "Child Block"
    refute list_text =~ "Other Block"
    refute list_text =~ attached_file.external_id

    assert Enum.map(list_raw["blocks"], & &1["block_id"]) |> Enum.sort() ==
             Enum.sort([child_block.id, duplicate_a.id, duplicate_b.id, root_block.id])

    assert {:ok, {page_zero_text, page_zero_raw}} =
             NativeKnowledgeLibrary.execute(tool, "read_block", %{
               "block_id" => root_block.id,
               "page" => 0
             })

    assert page_zero_raw["page"] == 1
    assert page_zero_text =~ "Visible root text"
    assert page_zero_text =~ "Attached files:"
    assert page_zero_text =~ "[Attached file file_id=#{attached_file.external_id}"
    refute page_zero_text =~ disabled_file.external_id
    assert [%{"file_id" => file_id, "filename" => "root.txt"}] = page_zero_raw["attachments"]
    assert file_id == attached_file.external_id
    refute Enum.any?(page_zero_raw["attachments"], &(&1["file_id"] == disabled_file.external_id))
    refute page_zero_text =~ "hidden root note"

    assert {:error, "Page out of range:" <> _} =
             NativeKnowledgeLibrary.execute(tool, "read_block", %{
               "block_id" => root_block.id,
               "page" => 999
             })

    assert {:error, "Multiple blocks have this name. Use `block_id` from list_blocks."} =
             NativeKnowledgeLibrary.execute(tool, "read_block", %{"block_name" => "Duplicate"})

    assert {:ok, {search_text, search_raw}} =
             NativeKnowledgeLibrary.execute(tool, "search_blocks", %{
               "regex" => "Visible",
               "max_snippets" => 1
             })

    assert search_text =~ "Matches: 1"
    refute search_text =~ attached_file.external_id
    assert length(search_raw["snippets"]) == 1

    assert {:ok, {hidden_search_text, hidden_search_raw}} =
             NativeKnowledgeLibrary.execute(tool, "search_blocks", %{
               "regex" => "hidden root note",
               "max_snippets" => 5
             })

    assert hidden_search_text =~ "Matches: none"
    assert hidden_search_raw["snippets"] == []

    context =
      NativeKnowledgeLibrary.instance_prompt_context(%{
        tool
        | config: Map.put(tool.config, "max_context_blocks", 1)
      })

    assert context =~ "Knowledge tag: Library"
    assert context =~ "The list is truncated"

    assert NativeKnowledgeLibrary.available_file_external_ids(tool) == [attached_file.external_id]
  end

  test "lists parsed SKILL.md descriptions in tool output and prompt context" do
    %{user: owner} = user_fixture()

    tag = create_knowledge_tag!(owner, name: "Skill Library")

    skill_description =
      "Use when the user asks for research: gather sources and summarize."

    skill_content = """
    ---
    name: "research-skill"
    description: "#{skill_description}"
    ---

    # Research Skill

    Read sources and prepare a concise answer.
    """

    block =
      create_knowledge_block!(owner,
        name: "Research Skill",
        version: "v1",
        content: skill_content
      )

    attach_tag!(owner, block, tag)

    tool = create_library_tool!(owner, tag.id)

    assert {:ok, {list_text, list_raw}} =
             NativeKnowledgeLibrary.execute(tool, "list_blocks", %{"max_results" => 10})

    assert list_text =~ "Research Skill"
    assert list_text =~ "description: #{skill_description}"
    assert [%{"block_id" => block_id, "description" => ^skill_description}] = list_raw["blocks"]
    assert block_id == block.id

    assert {:ok, {filtered_text, filtered_raw}} =
             NativeKnowledgeLibrary.execute(tool, "list_blocks", %{"q" => "gather sources"})

    assert filtered_text =~ "Research Skill"
    assert filtered_raw["total_blocks"] == 1

    context =
      NativeKnowledgeLibrary.instance_prompt_context(%{
        tool
        | config: Map.put(tool.config, "max_context_blocks", 10)
      })

    assert context =~ "- Research Skill (v1) - description: #{skill_description}"
  end

  test "search distributes limited snippets across matching blocks before filling extras" do
    %{user: owner} = user_fixture()

    tag = create_knowledge_tag!(owner, name: "Distributed Search Library")

    alpha_block =
      create_knowledge_block!(owner,
        name: "Alpha Block",
        version: "v1",
        content: "needle alpha first. #{String.duplicate("padding ", 16)} needle alpha second."
      )

    beta_block =
      create_knowledge_block!(owner,
        name: "Beta Block",
        version: "v1",
        content: "needle beta only."
      )

    gamma_block =
      create_knowledge_block!(owner,
        name: "Gamma Block",
        version: "v1",
        content: "needle gamma only."
      )

    attach_tag!(owner, alpha_block, tag)
    attach_tag!(owner, beta_block, tag)
    attach_tag!(owner, gamma_block, tag)

    tool = create_library_tool!(owner, tag.id)

    assert {:ok, {_search_text, limited_raw}} =
             NativeKnowledgeLibrary.execute(tool, "search_blocks", %{
               "regex" => "needle",
               "max_snippets" => 2,
               "snippet_len_chars" => 40
             })

    limited_block_ids = Enum.map(limited_raw["snippets"], & &1["block_id"])
    assert length(limited_block_ids) == 2
    assert Enum.uniq(limited_block_ids) == limited_block_ids
    assert limited_block_ids == [alpha_block.id, beta_block.id]

    assert {:ok, {_search_text, filled_raw}} =
             NativeKnowledgeLibrary.execute(tool, "search_blocks", %{
               "regex" => "needle",
               "max_snippets" => 4,
               "snippet_len_chars" => 40
             })

    assert Enum.map(filled_raw["snippets"], & &1["block_id"]) == [
             alpha_block.id,
             beta_block.id,
             gamma_block.id,
             alpha_block.id
           ]
  end

  test "shared recipients execute owner library without direct block access" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    tag = create_knowledge_tag!(owner, name: "Shared Library")

    block =
      create_knowledge_block!(owner,
        name: "Shared Block",
        version: "v1",
        content: "Owner-only library text"
      )

    attached_file =
      create_attachment!(owner, block, "shared.txt", "text/plain", "shared file payload")

    attach_tag!(owner, block, tag)

    tool = create_library_tool!(owner, tag.id)
    bot = create_bot!(owner, max_tool_rounds: 10, name: "Shared library bot")
    create_bot_tool_binding!(owner, bot, tool)
    share_bot!(owner, bot, group)

    assert {:error, _error} = Ash.get(KnowledgeBlock, block.id, actor: recipient)

    resolution = BindingResolver.resolve_for_chat(%{id: -1, bot_id: bot.id}, recipient)
    assert resolution.tool_instances_by_alias["library"].owner_id == owner.id

    result =
      Executor.execute_llm_tool(
        resolution.tool_instances_by_alias,
        "library__read_block",
        %{"block_id" => block.id},
        nil
      )

    assert result.raw["isError"] != true
    assert result.text =~ "Owner-only library text"
    assert result.text =~ "[Attached file file_id=#{attached_file.external_id}"

    allowed_ids = NativeKnowledgeLibrary.available_file_external_ids(tool)
    assert attached_file.external_id in allowed_ids

    context = %ExecutionContext{
      owner_id: recipient.id,
      chat_id: -1,
      available_file_external_ids: allowed_ids
    }

    assert {:ok, {nil, loaded_file, payload}} =
             ContentFiles.load_payload_for_execution(attached_file.external_id, context)

    assert loaded_file.id == attached_file.id
    assert payload == "shared file payload"
  end

  test "duplication preserves owner settings but does not transfer a tag or write grants to recipients" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    tag = create_knowledge_tag!(owner, name: "Source Library")
    tool = create_library_tool!(owner, tag.id)
    create_tool_function!(owner, tool, name: "create_block")
    attrs = %{"name" => "Copy", "content" => "Test"}

    owner_copy =
      ToolInstance
      |> Ash.Changeset.for_create(:duplicate, %{id: tool.id}, actor: owner)
      |> Ash.create!()

    assert owner_copy.config["knowledge_tag_id"] == tag.id
    assert call!(owner_copy, owner, "create_block", attrs)["block_id"]

    bot = create_bot!(owner, max_tool_rounds: 10, name: "Shared duplicate bot")
    create_bot_tool_binding!(owner, bot, tool)
    share_bot!(owner, bot, group)

    recipient_copy =
      ToolInstance
      |> Ash.Changeset.for_create(:duplicate, %{id: tool.id}, actor: recipient)
      |> Ash.create!()

    refute Map.has_key?(recipient_copy.config, "knowledge_tag_id")
    refute Map.has_key?(recipient_copy.config, :knowledge_tag_id)
    own_tag = create_knowledge_tag!(recipient)

    configured =
      Ash.update!(recipient_copy, %{config: %{"knowledge_tag_id" => own_tag.id}},
        action: :update,
        actor: recipient
      )

    assert_tool_error(
      library_call(configured, recipient, "create_block", attrs),
      "tool_function_disabled"
    )
  end

  test "config validation rejects tags outside the tool owner authority" do
    %{user: owner} = user_fixture()
    %{user: other_owner} = user_fixture()

    foreign_tag = create_knowledge_tag!(other_owner, name: "Foreign Library")

    assert {:error, error} =
             ToolInstance
             |> Ash.Changeset.for_create(
               :create,
               %{
                 type: "native-knowledge-library",
                 name: "Invalid Library",
                 alias: "invalid_library",
                 config: %{"knowledge_tag_id" => foreign_tag.id},
                 secrets: %{}
               },
               actor: owner
             )
             |> Ash.create()

    assert Exception.message(error) =~ "Knowledge tag is not available."
  end

  @writes ~w(create_block edit_block delete_block)

  describe "writing library blocks" do
    setup tags do
      %{user: owner} = user_fixture()
      root = create_knowledge_tag!(owner)
      tool = create_library_tool!(owner, root.id, Map.get(tags, :library_config, %{}))

      for name <- Map.get(tags, :enabled_writes, []) do
        create_tool_function!(owner, tool, name: name)
      end

      %{owner: owner, root: root, tool: tool}
    end

    test "each write requires a separate opt-in and shared recipients stay read-only", ctx do
      %{owner: owner, root: root, tool: tool} = ctx
      %{user: recipient} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [owner, recipient]})
      bot = create_bot!(owner)
      create_bot_tool_binding!(owner, bot, tool)
      share_bot!(owner, bot, group)

      visible = fn actor ->
        BindingResolver.resolve_for_chat(%{id: -1, bot_id: bot.id}, actor).tools_payload
        |> Enum.map(&String.replace_prefix(&1["function"]["name"], "library__", ""))
        |> Enum.sort()
      end

      block = create_knowledge_block!(owner, tag_bindings: [%{knowledge_tag_id: root.id}])
      target = call!(tool, owner, "read_block", %{"block_id" => block.id}) |> write_target()

      calls = [
        {"create_block", %{"name" => "Another", "content" => "text"}},
        {"edit_block", Map.put(target, "append_text", "!")},
        {"delete_block", target}
      ]

      reads = ~w(list_blocks read_block search_blocks)
      assert visible.(owner) == reads

      for {name, args} <- calls do
        assert_tool_error(library_call(tool, owner, name, args), "tool_function_disabled")
      end

      create_tool_function!(owner, tool, name: "edit_block")
      assert visible.(owner) == Enum.sort(["edit_block" | reads])

      for name <- ~w(create_block delete_block),
          do: create_tool_function!(owner, tool, name: name)

      assert visible.(owner) == Enum.sort(@writes ++ reads)
      assert visible.(recipient) == reads

      assert call!(tool, recipient, "read_block", %{"block_id" => block.id})["block_id"] ==
               block.id

      for actor <- [recipient, nil], {name, args} <- calls do
        assert_tool_error(library_call(tool, actor, name, args))
      end

      assert call!(tool, owner, "list_blocks", %{})["total_blocks"] == 1
      assert Ash.get!(KnowledgeBlock, block.id, actor: owner).content == block.content
    end

    @tag enabled_writes: ~w(create_block delete_block)
    test "creates new blocks at the root, exposes their revisions, and deletes only the requested id",
         %{tool: tool, owner: owner, root: root} do
      attrs = %{"name" => "Identical", "content" => "", "version" => "manual label"}
      outside = create_knowledge_tag!(owner)

      for invalid <- [
            Map.put(attrs, "tag_id", outside.id),
            Map.put(attrs, "owner_id", owner.id),
            Map.delete(attrs, "content"),
            Map.put(attrs, "name", "   ")
          ] do
        assert_tool_error(library_call(tool, owner, "create_block", invalid), "invalid_arguments")
      end

      first = call!(tool, owner, "create_block", attrs)
      second = call!(tool, owner, "create_block", Map.put(attrs, "content", "keep this"))
      assert first["block_id"] != second["block_id"]
      assert %{"name" => "Identical", "version" => "manual label", "token_count" => 0} = first
      assert is_binary(first["revision"]) and first["revision"] != ""

      block = Ash.get!(KnowledgeBlock, first["block_id"], actor: owner, load: :tag_bindings)
      assert block.owner_id == owner.id
      assert Enum.map(block.tag_bindings, & &1.knowledge_tag_id) == [root.id]

      listed = library_call(tool, owner, "list_blocks", %{})
      assert listed.text =~ first["revision"]

      assert Enum.map(listed.raw["blocks"], &write_target/1) ==
               Enum.map([first, second], &write_target/1)

      read = library_call(tool, owner, "read_block", %{"block_id" => block.id})
      assert read.text =~ first["revision"]
      assert read.raw["revision"] == first["revision"]

      child = create_knowledge_tag!(owner, parent_id: root.id)
      attach_tag!(owner, block, child)

      assert_tool_error(
        library_call(tool, owner, "delete_block", %{"block_id" => block.id}),
        "invalid_arguments"
      )

      assert %{"deleted" => true, "block_id" => deleted_id} =
               call!(tool, owner, "delete_block", write_target(first))

      assert deleted_id == block.id
      assert_missing!(KnowledgeBlock, block.id, owner)
      assert Ash.get!(KnowledgeBlock, second["block_id"], actor: owner).content == "keep this"
    end

    @tag enabled_writes: ["edit_block"]
    test "edits child blocks literally and in order without touching comment lines or bindings",
         %{tool: tool, owner: owner, root: root} do
      child = create_knowledge_tag!(owner, parent_id: root.id)
      literal = "  heading  \r\n\tfirst.*  "
      hidden = "//// first.* private note\r\n"
      content = literal <> "\r\n" <> hidden <> "\r\n  end  \n"

      block =
        create_knowledge_block!(owner,
          content: content,
          tag_bindings: [%{knowledge_tag_id: child.id}]
        )

      file = create_attachment!(owner, block, "unrelated.txt", "text/plain", "file content")
      read_args = %{"block_id" => block.id}
      old = call!(tool, owner, "read_block", read_args)
      editable = library_call(tool, owner, "read_block", Map.put(read_args, "view", "edit"))
      assert editable.text =~ old["revision"]
      assert [before_comment, after_comment] = editable.raw["fragments"]
      assert before_comment =~ literal
      assert after_comment =~ "\r\n  end  \n"
      refute editable.text =~ "private note"
      refute inspect(editable.raw["fragments"]) =~ file.external_id

      args =
        Map.merge(write_target(old), %{
          "name" => "New name",
          "version" => "v2",
          "append_text" => "  last\n",
          "replacements" => [
            %{"old_text" => literal, "new_text" => "intermediate"},
            %{"old_text" => "intermediate", "new_text" => "  revised"},
            %{"old_text" => "end", "new_text" => ""}
          ]
        })

      updated = call!(tool, owner, "edit_block", args)
      assert %{"name" => "New name", "version" => "v2"} = updated
      assert updated["block_id"] == block.id
      assert updated["revision"] != old["revision"]

      stored = Ash.get!(KnowledgeBlock, block.id, actor: owner, load: :tag_bindings)
      assert stored.content == "  revised\r\n" <> hidden <> "\r\n    \n  last\n"
      assert Enum.map(stored.tag_bindings, & &1.knowledge_tag_id) == [child.id]
      reread = library_call(tool, owner, "read_block", read_args)
      assert reread.text =~ "revised"
      assert [%{"file_id" => file_id}] = reread.raw["attachments"]
      assert file_id == file.external_id
    end

    @tag enabled_writes: ["edit_block"]
    test "a replacement cannot expose a hidden line and an append cannot extend it",
         %{tool: tool, owner: owner, root: root} do
      block =
        create_knowledge_block!(owner,
          content: "aaa\n//// personal",
          tag_bindings: [%{knowledge_tag_id: root.id}]
        )

      target = call!(tool, owner, "read_block", %{"block_id" => block.id}) |> write_target()

      for {literal, code} <- [{"aa", "ambiguous_match"}, {"aaa\n", "invalid_arguments"}] do
        args = Map.put(target, "replacements", [%{"old_text" => literal, "new_text" => "b"}])
        assert_tool_error(library_call(tool, owner, "edit_block", args), code)
      end

      call!(tool, owner, "edit_block", Map.put(target, "append_text", "new text"))

      assert Ash.get!(KnowledgeBlock, block.id, actor: owner).content ==
               "aaa\n//// personal\nnew text"
    end

    test "a previously resolved instance cannot write through a stale tag or switch",
         %{tool: tool, owner: owner, root: root} do
      block = create_knowledge_block!(owner, tag_bindings: [%{knowledge_tag_id: root.id}])
      target = call!(tool, owner, "read_block", %{"block_id" => block.id}) |> write_target()
      switch = create_tool_function!(owner, tool, name: "edit_block")
      args = Map.put(target, "append_text", "!")
      next_tag = create_knowledge_tag!(owner)

      Ash.update!(tool, %{config: %{"knowledge_tag_id" => next_tag.id}},
        action: :update,
        actor: owner
      )

      assert_tool_error(library_call(tool, owner, "edit_block", args), "block_not_available")
      Ash.update!(switch, %{enabled: false}, action: :update, actor: owner)
      assert_tool_error(library_call(tool, owner, "edit_block", args), "tool_function_disabled")
      assert Ash.get!(KnowledgeBlock, block.id, actor: owner).content == block.content
    end

    @tag library_config: %{"chunk_size_tokens" => 32}
    test "edit pages round-trip whitespace and UTF-8, including empty and comment-only blocks",
         %{tool: tool, owner: owner, root: root} do
      long_text = String.duplicate(" \tαβ🙂  \r\n\n", 200) <> "   "

      for {source, expected} <- [{long_text, long_text}, {"", ""}, {"//// private", ""}] do
        block =
          create_knowledge_block!(owner,
            content: source,
            tag_bindings: [%{knowledge_tag_id: root.id}]
          )

        args = %{"block_id" => block.id, "view" => "edit"}
        first = call!(tool, owner, "read_block", args)
        total = first["pages_total"]
        assert total >= 1
        if expected != "", do: assert(total > 1)

        text =
          Enum.map_join(1..total, fn page ->
            raw =
              if page == 1,
                do: first,
                else: call!(tool, owner, "read_block", Map.put(args, "page", page))

            assert raw["revision"] == first["revision"]
            Enum.join(raw["fragments"])
          end)

        assert text == expected

        assert_tool_error(
          library_call(tool, owner, "read_block", Map.put(args, "page", total + 1))
        )
      end
    end

    @tag enabled_writes: ~w(edit_block delete_block)
    test "failed matches roll back the entire edit and an intervening catalog edit invalidates both writes",
         %{tool: tool, owner: owner, root: root} do
      content = "first repeat\nboundary\n//// hidden\nnext repeat"

      block =
        create_knowledge_block!(owner,
          content: content,
          tag_bindings: [%{knowledge_tag_id: root.id}]
        )

      target = call!(tool, owner, "read_block", %{"block_id" => block.id}) |> write_target()

      missing_revision = %{"block_id" => block.id, "append_text" => "!"}

      assert_tool_error(
        library_call(tool, owner, "edit_block", missing_revision),
        "invalid_arguments"
      )

      assert_tool_error(library_call(tool, owner, "edit_block", target), "invalid_arguments")

      for unmatched <- ["repeat", "missing", "//// hidden", "boundary\nnext", ""] do
        args =
          Map.merge(target, %{
            "name" => "must roll back",
            "append_text" => "!",
            "replacements" => [
              %{"old_text" => "first", "new_text" => "changed"},
              %{"old_text" => unmatched, "new_text" => "invalid"}
            ]
          })

        assert_tool_error(library_call(tool, owner, "edit_block", args))
      end

      stored = Ash.get!(KnowledgeBlock, block.id, actor: owner)
      assert {stored.name, stored.content} == {block.name, content}

      assert call!(tool, owner, "read_block", %{"block_id" => block.id})["revision"] ==
               target["expected_revision"]

      Ash.update!(stored, %{content: "Changed in catalog"}, action: :update, actor: owner)

      for {name, args} <- [
            {"edit_block", Map.put(target, "version", "stale")},
            {"delete_block", target}
          ] do
        assert_tool_error(library_call(tool, owner, name, args), "revision_conflict")
      end

      assert Ash.get!(KnowledgeBlock, block.id, actor: owner).content == "Changed in catalog"
    end

    @tag enabled_writes: ~w(edit_block delete_block)
    test "out-of-scope, foreign and missing block ids are equally unavailable",
         %{tool: tool, owner: owner, root: root} do
      outside = create_knowledge_block!(owner)
      %{user: other} = user_fixture()
      foreign = create_knowledge_block!(other)
      moving = create_knowledge_block!(owner, tag_bindings: [%{knowledge_tag_id: root.id}])
      target = call!(tool, owner, "read_block", %{"block_id" => moving.id}) |> write_target()
      Ash.update!(moving, %{tag_bindings: []}, action: :update, actor: owner)

      for id <- [moving.id, outside.id, foreign.id, moving.id + 1_000_000] do
        args = Map.put(target, "block_id", id)

        assert_tool_error(
          library_call(tool, owner, "edit_block", Map.put(args, "append_text", "!")),
          "block_not_available"
        )

        assert_tool_error(library_call(tool, owner, "delete_block", args), "block_not_available")
      end
    end

    @tag enabled_writes: ["delete_block"]
    test "deletion preserves externally used blocks, including disabled and private bindings",
         %{tool: tool, owner: owner, root: root} do
      %{user: other} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [owner, other]})
      outside = create_knowledge_tag!(owner)
      bot = create_bot!(owner)
      chat = create_empty_chat!(other)
      config = create_configuration!(owner)
      image = create_file!()
      secret = create!(Secret, %{name: "Test credential", value: "fixture-value"}, owner)

      share = fn b ->
        create!(KnowledgeBlockShare, %{knowledge_block_id: b.id, user_group_id: group.id}, owner)
      end

      dependencies = [
        outside_tag: &attach_tag!(owner, &1, outside),
        profile: &create!(UserKnowledgeBlock, %{knowledge_block_id: &1.id}, owner),
        bot: &create!(BotKnowledgeBlock, %{bot_id: bot.id, knowledge_block_id: &1.id}, owner),
        handoff: &create_bot!(owner, handoff_message_block_id: &1.id),
        config:
          &create!(
            LlmConfigurationKnowledgeBlock,
            %{llm_configuration_id: config.id, knowledge_block_id: &1.id},
            owner
          ),
        share: share,
        private_chat: fn block ->
          grant = share.(block)
          binding = create_chat_block_binding!(other, chat, block, enabled: false)
          Ash.destroy!(grant, actor: owner)
          assert_missing!(ChatKnowledgeBlock, binding.id, owner)
        end,
        file: &create_attachment!(owner, &1, "disabled.txt", "text/plain", "payload", false),
        image:
          &Ash.update!(&1, %{image_file_id: image.id}, action: :attach_image_file, actor: owner),
        secret:
          &create!(
            KnowledgeBlockSecret,
            %{knowledge_block_id: &1.id, secret_id: secret.id, env_name: "TEST_KEY"},
            owner
          )
      ]

      for {kind, add_dependency} <- dependencies do
        block =
          create_knowledge_block!(owner,
            name: to_string(kind),
            tag_bindings: [%{knowledge_tag_id: root.id}]
          )

        add_dependency.(block)

        target =
          call!(tool, owner, "read_block", %{"block_id" => block.id, "view" => "edit"})
          |> write_target()

        result = library_call(tool, owner, "delete_block", target)
        assert result.raw["code"] == "block_in_use", "#{kind}: #{inspect(result.raw)}"
        assert result.raw["isError"] == true
        assert Ash.get!(KnowledgeBlock, block.id, actor: owner).id == block.id
      end
    end
  end

  defp library_call(tool, actor, name, args) do
    context = if actor, do: %ExecutionContext{owner_id: actor.id}
    Executor.execute_llm_tool(%{"library" => tool}, "library__#{name}", args, context)
  end

  defp call!(tool, actor, name, args) do
    result = library_call(tool, actor, name, args)
    refute result.raw["isError"], result.text
    result.raw
  end

  defp write_target(%{"block_id" => id, "revision" => revision}) when is_binary(revision),
    do: %{"block_id" => id, "expected_revision" => revision}

  defp assert_tool_error(result, code \\ nil) do
    assert result.raw["isError"] == true, inspect(result.raw)
    if code, do: assert(result.raw["code"] == code, result.text)
  end

  defp attach_tag!(actor, block, tag) do
    KnowledgeBlockTag
    |> Ash.Changeset.for_create(
      :create,
      %{knowledge_block_id: block.id, knowledge_tag_id: tag.id},
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_attachment!(actor, block, filename, mime_type, payload, enabled \\ true) do
    {:ok, file} = Files.create_from_binary(filename, mime_type, payload)

    KnowledgeBlockFile
    |> Ash.Changeset.for_create(
      :create,
      %{knowledge_block_id: block.id, file_id: file.id, enabled: enabled, sequence: 0},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    file
  end

  defp create_library_tool!(actor, tag_id, config_overrides \\ %{}) do
    config = Map.merge(%{"knowledge_tag_id" => tag_id}, config_overrides)

    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-knowledge-library",
        name: "Knowledge Library",
        alias: "library",
        config: config,
        secrets: %{}
      },
      actor: actor
    )
    |> Ash.create!()
  end
end
