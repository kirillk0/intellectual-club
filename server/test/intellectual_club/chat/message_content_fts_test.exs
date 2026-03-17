defmodule IntellectualClub.Chat.MessageContentFtsTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Chat.MessageContentFts

  test "build trims input and deduplicates normalized tokens" do
    assert %MessageContentFts{
             tokens: ["hello"],
             match: ~s("hello"*)
           } = MessageContentFts.build("  Hello hello  ")
  end

  test "build ignores punctuation and joins tokens with AND prefix search" do
    assert %MessageContentFts{
             tokens: ["alpha", "beta"],
             match: ~s("alpha"* AND "beta"*)
           } = MessageContentFts.build("alpha, beta + alpha")
  end

  test "build returns nil when the query has no unicode61 tokens" do
    assert nil == MessageContentFts.build("!!! ...")
  end
end
