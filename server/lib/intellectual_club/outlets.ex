defmodule IntellectualClub.Outlets do
  @moduledoc """
  Outlets domain (Ash).

  The domain currently stores persistent records required by outlet runners,
  such as device-flow pairing requests.
  """

  use Ash.Domain

  resources do
    resource(IntellectualClub.Outlets.PairingRequest)
  end
end
