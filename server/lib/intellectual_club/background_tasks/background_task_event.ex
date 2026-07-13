defmodule IntellectualClub.BackgroundTasks.BackgroundTaskEvent do
  @moduledoc """
  Append-only output chunks for cursor-based background task progress.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.BackgroundTasks,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("background_task_events")
    repo(IntellectualClub.Repo)

    custom_indexes do
      index([:background_task_id, :id], name: "background_task_events_task_id_index")
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :stream, :atom do
      allow_nil?(false)
      constraints(one_of: [:stdout, :stderr])
    end

    attribute :data, :string do
      allow_nil?(false)
      constraints(trim?: false, allow_empty?: true)
    end

    attribute :byte_size, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
    end

    create_timestamp(:created_at)
  end

  relationships do
    belongs_to :background_task, IntellectualClub.BackgroundTasks.BackgroundTask,
      allow_nil?: false,
      attribute_type: :uuid

    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer
  end

  actions do
    defaults([:read])

    create :append do
      public?(false)
      accept([:background_task_id, :stream, :data, :byte_size])
      change(relate_actor(:owner))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end
  end
end
