defmodule IntellectualClub.Generation.RequestImages.StagedBindings do
  @moduledoc """
  Opaque logical files prepared before immutable request publication or copying.

  A staged value must be attached to a new step or discarded by the caller after
  rollback. Preparation never attaches files to an existing request snapshot.
  """

  @enforce_keys [:items]
  defstruct [:items]

  @type item :: %{
          required(:file_id) => integer(),
          required(:reference_key) => String.t(),
          required(:source_file_external_id) => String.t(),
          required(:variant_key) => String.t()
        }

  @type t :: %__MODULE__{items: [item()]}

  @doc false
  def with_scope(fun, cleanup) when is_function(fun, 1) and is_function(cleanup, 1) do
    # Provider callbacks may raise after creating a file but before returning the
    # accumulator. Keep a private journal independent of callback return values.
    journal = :ets.new(__MODULE__, [:set, :private])
    track = fn item -> :ets.insert(journal, {item.file_id, item}) end

    try do
      fun.(track)
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        items = Enum.map(:ets.tab2list(journal), &elem(&1, 1))

        case cleanup.(items) do
          :ok ->
            :erlang.raise(kind, reason, stacktrace)

          {:error, cleanup_error} ->
            raise "Image staging cleanup failed after #{kind}: #{inspect(cleanup_error)}"
        end
    after
      :ets.delete(journal)
    end
  end
end
