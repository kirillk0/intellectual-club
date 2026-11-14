defmodule IntellectualClub.Files.ImageProviderVerdictsTest do
  @moduledoc """
  `IntellectualClub.Files.ImageProviderVerdicts`: facts about what one LLM
  configuration did with an image payload, isolated per configuration, written
  in one statement and removable from the console.
  """

  use IntellectualClub.DataCase, async: true

  import IntellectualClub.SqlCapture, only: [capture_queries: 2]

  alias IntellectualClub.Files.ImageProviderVerdicts

  setup do
    %{user: actor} = user_fixture()

    %{
      actor: actor,
      first: create_configuration!(actor).id,
      second: create_configuration!(actor).id
    }
  end

  describe "load/2" do
    test "returns the facts of one configuration for many hashes with one query", ctx do
      :ok = ImageProviderVerdicts.record_accepted([sha("a")], ctx.first)
      :ok = ImageProviderVerdicts.mark_rejected([sha("b")], ctx.first, "test: no")
      :ok = ImageProviderVerdicts.mark_rejected([sha("a"), sha("c")], ctx.second, "test: no")

      {result, queries} =
        callers_queries(fn ->
          ImageProviderVerdicts.load([sha("a"), sha("b"), sha("c"), sha("a"), "bad"], ctx.first)
        end)

      assert result == {:ok, %{sha("a") => :accepted, sha("b") => :rejected}}
      assert length(queries) == 1

      assert {{:ok, %{}}, []} =
               callers_queries(fn -> ImageProviderVerdicts.load([sha("a")], nil) end)

      assert {{:ok, %{}}, []} =
               callers_queries(fn -> ImageProviderVerdicts.load([], ctx.first) end)
    end
  end

  describe "mark_rejected/3" do
    test "overwrites earlier facts of the configuration in one statement", ctx do
      :ok = ImageProviderVerdicts.record_accepted([sha("a")], ctx.first)
      :ok = ImageProviderVerdicts.mark_rejected([sha("b")], ctx.first, "test: first")

      {result, queries} =
        callers_queries(fn ->
          ImageProviderVerdicts.mark_rejected(
            [sha("b"), sha("a"), sha("b")],
            ctx.first,
            "test: again"
          )
        end)

      assert result == :ok
      assert Enum.count(queries, &(&1 =~ ~r/INSERT INTO "image_provider_verdicts"/)) == 1
      assert image_provider_verdicts(sha("a")) == %{ctx.first => {:rejected, "test: again"}}
      assert image_provider_verdicts(sha("b")) == %{ctx.first => {:rejected, "test: again"}}
    end

    test "truncates details and validates its arguments", ctx do
      assert :ok = ImageProviderVerdicts.mark_rejected([], ctx.first, "nothing")
      long = String.duplicate("x", 5_000)
      assert :ok = ImageProviderVerdicts.mark_rejected([sha("e")], ctx.first, long)
      first = ctx.first
      assert %{^first => {:rejected, details}} = image_provider_verdicts(sha("e"))
      assert String.length(details) == 1_000
      assert :ok = ImageProviderVerdicts.mark_rejected([sha("f")], ctx.first)
      assert image_provider_verdicts(sha("f")) == %{ctx.first => {:rejected, nil}}

      assert {:error, :invalid_sha256} =
               ImageProviderVerdicts.mark_rejected([String.upcase(sha("a"))], ctx.first)

      assert {:error, :invalid_sha256} = ImageProviderVerdicts.mark_rejected(["short"], ctx.first)
      assert {:error, :invalid_arguments} = ImageProviderVerdicts.mark_rejected([sha("a")], nil)

      assert {:error, :invalid_arguments} =
               ImageProviderVerdicts.mark_rejected(sha("a"), ctx.first)
    end
  end

  describe "record_accepted/2" do
    test "adds missing facts in one statement and never undoes a rejection", ctx do
      :ok = ImageProviderVerdicts.mark_rejected([sha("b")], ctx.first, "test: no")

      {result, queries} =
        callers_queries(fn ->
          ImageProviderVerdicts.record_accepted([sha("a"), sha("b"), sha("a")], ctx.first)
        end)

      assert result == :ok
      assert Enum.count(queries, &(&1 =~ ~r/INSERT INTO "image_provider_verdicts"/)) == 1
      assert image_provider_verdicts(sha("a")) == %{ctx.first => {:accepted, nil}}
      assert image_provider_verdicts(sha("b")) == %{ctx.first => {:rejected, "test: no"}}

      assert :ok = ImageProviderVerdicts.record_accepted([sha("a")], ctx.first)
      assert :ok = ImageProviderVerdicts.record_accepted([], ctx.first)
      assert {:error, :invalid_sha256} = ImageProviderVerdicts.record_accepted(["x"], ctx.first)
      assert {:error, :invalid_arguments} = ImageProviderVerdicts.record_accepted([sha("a")], "1")
    end
  end

  describe "forget/2" do
    test "removes facts by hash, optionally of one configuration, or all of a configuration",
         ctx do
      for config <- [ctx.first, ctx.second],
          do: :ok = ImageProviderVerdicts.mark_rejected([sha("a"), sha("b")], config, "test")

      assert {:ok, 1} = ImageProviderVerdicts.forget([sha("a")], llm_configuration_id: ctx.first)
      assert image_provider_verdicts(sha("a")) == %{ctx.second => {:rejected, "test"}}

      assert {:ok, 1} = ImageProviderVerdicts.forget([sha("a")])
      assert image_provider_verdicts(sha("a")) == %{}

      assert {:ok, 1} = ImageProviderVerdicts.forget(:all, llm_configuration_id: ctx.second)
      assert image_provider_verdicts(sha("b")) == %{ctx.first => {:rejected, "test"}}

      assert {:ok, 0} = ImageProviderVerdicts.forget([])
      assert {:error, :invalid_sha256} = ImageProviderVerdicts.forget(["x"])

      assert {:error, :invalid_llm_configuration_id} =
               ImageProviderVerdicts.forget([sha("b")], llm_configuration_id: "1")
    end

    test "facts are deleted together with their configuration", ctx do
      :ok = ImageProviderVerdicts.mark_rejected([sha("a")], ctx.first, "test")
      :ok = ImageProviderVerdicts.record_accepted([sha("a")], ctx.second)

      configuration = Ash.get!(IntellectualClub.Llm.LlmConfiguration, ctx.first, actor: ctx.actor)
      :ok = Ash.destroy!(configuration, actor: ctx.actor)

      assert image_provider_verdicts(sha("a")) == %{ctx.second => {:accepted, nil}}
    end
  end

  defp sha(char), do: String.duplicate(char, 64)

  defp callers_queries(fun), do: capture_queries(fun, processes: :callers)
end
