defmodule IntellectualClub.Tools.WebSearch.Provider do
  @moduledoc "Provider contract for normalized web search and document retrieval."

  @callback search(map(), map()) :: {:ok, map()} | {:error, map()}
  @callback fetch(map(), list(String.t()), struct()) :: {:ok, map()} | {:error, map()}
end
