defmodule IntellectualClub.TokenCounter do
  @moduledoc """
  Token estimation helpers.

  The prototype uses a fast heuristic instead of model-specific tokenizers.
  """

  @doc """
  Estimates token count for the given text.
  """
  @spec estimate(String.t() | nil) :: non_neg_integer()
  def estimate(text) do
    text = text || ""
    ceil(byte_size(text) / 3.5)
  end
end
