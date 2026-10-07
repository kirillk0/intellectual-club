defmodule IntellectualClub.ApplicationTest do
  use ExUnit.Case, async: true

  describe "start/2" do
    test "loads every application module, so callback checks see all implementations" do
      {:ok, modules} = :application.get_key(:intellectual_club, :modules)

      assert Enum.reject(modules, &:erlang.module_loaded/1) == []
    end
  end
end
