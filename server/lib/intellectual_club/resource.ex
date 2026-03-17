defmodule IntellectualClub.Resource do
  @moduledoc """
  Shared Ash resource wrapper.

  All project resources use `IntellectualClub.DataLayer`, which delegates to
  SQLite or PostgreSQL at runtime.
  """

  defmacro __using__(opts) do
    opts = Keyword.put_new(opts, :data_layer, IntellectualClub.DataLayer)

    quote do
      use Ash.Resource, unquote(opts)
    end
  end
end
