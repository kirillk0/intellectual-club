defmodule IntellectualClub.Chat.LinkedForkCleanup.Plan do
  @moduledoc """
  Transaction-local discovery of one linked-fork cleanup operation.

  `deleted` contains only records removed by the requested scope and its linked
  dependents. `locks` additionally contains surviving task authorities, ancestors,
  legacy references and, for reparenting, the direct children and parent. An
  ancestor's anchor step is read for discovery, but is not itself deleted/locked.

  `root_record` uses the resource's default selection (no raw provider payloads).
  For a retry range it is the retained message, while `barrier` identifies the
  first deleted step by sequence. An empty range has a nil barrier. Every other
  scope uses its deleted root as the commit barrier.

  This value is not a reusable authorization capability: its fences are valid
  only inside the transaction and lexical operation which prepared it.
  """

  @type scope ::
          {:chat, integer()}
          | {:message, integer()}
          | {:message_tree, integer()}
          | {:message_keep_children, integer()}
          | {:steps, integer(), integer()}
          | {:step, integer()}

  @type t :: %__MODULE__{
          scope: scope(),
          owner_id: integer(),
          root_record: struct(),
          barrier: {module(), integer()} | nil,
          deleted: %{chats: map(), messages: map(), steps: map()},
          item_ids: MapSet.t(integer()),
          locks: %{
            chats: MapSet.t(integer()),
            messages: MapSet.t(integer()),
            steps: MapSet.t(integer())
          }
        }

  @enforce_keys [:scope, :owner_id, :root_record, :barrier, :deleted, :item_ids, :locks]
  defstruct @enforce_keys
end
