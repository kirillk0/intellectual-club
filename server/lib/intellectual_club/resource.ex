defmodule IntellectualClub.Resource do
  @moduledoc """
  Shared Ash resource wrapper.
  """

  defmacro __using__(opts) do
    opts = Keyword.put_new(opts, :data_layer, AshPostgres.DataLayer)

    quote do
      use Ash.Resource, unquote(opts)
    end
  end
end
