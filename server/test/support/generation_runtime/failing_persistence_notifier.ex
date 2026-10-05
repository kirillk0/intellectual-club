defmodule IntellectualClub.Test.FailingPersistenceNotifier do
  @moduledoc false
  use Ash.Notifier

  def notify(notification) do
    send(notification.metadata.test, :post_commit_notification)

    raise %Postgrex.Error{
      postgres: %{
        code: :deadlock_detected,
        pg_code: "40P01",
        severity: "ERROR",
        message: "Injected notifier deadlock"
      }
    }
  end
end
