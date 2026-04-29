defmodule IntellectualClub.Llm.Providers.Demo.Stream do
  @moduledoc """
  A local streaming provider used for the prototype.

  It emits `{:content_delta, chunk}` events and finishes with
  `{:response_complete, meta}`.
  """

  def run(input, opts \\ [], emit)

  def run(prompt, opts, emit) when is_binary(prompt) and is_function(emit, 1) do
    run([%{"role" => "user", "content" => prompt}], opts, emit)
  end

  def run(messages, opts, emit) when is_list(messages) and is_function(emit, 1) do
    chunk_delay_ms = Keyword.get(opts, :chunk_delay_ms, 40)
    prompt = extract_last_user_prompt(messages)
    response = build_response(prompt)

    response
    |> split_into_chunks()
    |> Enum.each(fn chunk ->
      emit.({:content_delta, chunk})

      if chunk_delay_ms > 0 do
        Process.sleep(chunk_delay_ms)
      end
    end)

    emit.({:response_complete, %{provider: :demo}})
    :ok
  end

  defp build_response(prompt) do
    prompt = String.trim(prompt || "")

    base =
      [
        "This is a demo response generated locally.",
        "It streams in small chunks to exercise LiveView + PubSub.",
        "No external LLM calls are made."
      ]
      |> Enum.join(" ")

    if prompt == "" do
      base <> " Send a message to see an echo."
    else
      base <> " You said: " <> prompt
    end
  end

  defp split_into_chunks(text) do
    String.split(text, ~r/(\s+)/, include_captures: true, trim: true)
  end

  defp extract_last_user_prompt(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn message ->
      role = Map.get(message, "role")

      if role == "user" do
        Map.get(message, "content") |> to_string()
      else
        nil
      end
    end)
  end
end
