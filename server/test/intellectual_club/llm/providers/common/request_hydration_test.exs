defmodule IntellectualClub.Llm.Providers.Common.RequestHydrationTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageStep, ChatMessageStepRequestFile}
  alias IntellectualClub.Files
  alias IntellectualClub.Generation.RequestImages
  alias IntellectualClub.Llm.Providers.AnthropicMessages
  alias IntellectualClub.Llm.Providers.Common.PreparedRequest
  alias IntellectualClub.Llm.Providers.GoogleInteractions
  alias IntellectualClub.Llm.Providers.NvidiaBuildChatCompletion
  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion
  alias IntellectualClub.Llm.Providers.Responses

  test "successful senders hydrate only the wire body and preserve the persisted logical map" do
    %{user: actor} = user_fixture()
    parent = self()

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{chat_id: chat.id, role: :assistant, status: :done, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    image = IntellectualClub.ImageFixtures.png(1, 1)
    encoded_image = Base.encode64(image)

    adapters = [
      Responses,
      OpenRouterChatCompletion,
      NvidiaBuildChatCompletion,
      AnthropicMessages,
      GoogleInteractions
    ]

    for {adapter, sequence} <- Enum.with_index(adapters, 1) do
      {:ok, file} = Files.create_from_binary("request.png", "image/png", image)
      marker = RequestImages.marker(to_string(file.external_id), "image/png")
      base64_marker = put_in(marker, ["$intellectual_club_file", "encoding"], "base64")
      request = image_request(adapter, marker, base64_marker)

      context = %{
        provider_type: adapter.type(),
        provider_auth_method: "api_key",
        provider_api_key: "test-key",
        owner_id: actor.id,
        chat_id: chat.id
      }

      prepared = PreparedRequest.prepare(adapter, request, context)

      step =
        ChatMessageStep
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_id: message.id,
            sequence: sequence,
            status: :done,
            raw_request: prepared
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      ChatMessageStepRequestFile
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_step_id: step.id,
          file_id: file.id,
          reference_key: file.external_id,
          source_file_external_id: file.external_id,
          variant_key: "identity:v1"
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

      wire =
        image_request(adapter, "data:image/png;base64," <> encoded_image, encoded_image)
        |> then(&PreparedRequest.prepare(adapter, &1, context))
        |> Map.drop(["anthropic_version", "anthropic_beta"])

      handler = fn conn, _opts ->
        assert conn.method == "POST"
        assert conn.request_path == request_path(adapter)
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == wire
        send(parent, {:wire_request, adapter, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, completion_event(adapter))
      end

      server =
        start_supervised!(
          Supervisor.child_spec({Bandit, plug: handler, scheme: :http, port: 0},
            id: {Bandit, adapter}
          )
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)
      context = Map.put(context, :provider_base_url, "http://127.0.0.1:#{port}")

      assert :ok =
               adapter.stream_generate(
                 %{
                   context: context,
                   request_payload: prepared,
                   request_step_id: step.id,
                   timeout_ms: 1_000
                 },
                 fn event -> send(parent, {:provider_event, event}) end
               )

      assert_receive {:wire_request, ^adapter, ^wire}
      assert_receive {:provider_event, {:response_complete, %{raw_request: ^prepared}}}
      refute_receive {:provider_event, {:response_error, _}}, 0
      refute_receive {:provider_event, {:trace, {:set_step_raw_request, _}}}, 0

      persisted = Ash.get!(ChatMessageStep, step.id, actor: actor, load: [:raw_request])
      assert persisted.raw_request == prepared
    end
  end

  defp image_request(Responses, data_url, _base64) do
    %{
      "model" => "test",
      "stream" => true,
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_image", "image_url" => data_url}]
        }
      ]
    }
  end

  defp image_request(AnthropicMessages, _data_url, base64) do
    %{
      "model" => "test",
      "stream" => true,
      "anthropic_beta" => ["beta-a"],
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "image",
              "source" => %{"type" => "base64", "media_type" => "image/png", "data" => base64}
            }
          ]
        }
      ]
    }
  end

  defp image_request(GoogleInteractions, _data_url, base64) do
    %{
      "model" => "test",
      "stream" => true,
      "input" => [
        %{
          "type" => "user_input",
          "content" => [%{"type" => "image", "mime_type" => "image/png", "data" => base64}]
        }
      ]
    }
  end

  defp image_request(_chat_provider, data_url, _base64) do
    %{
      "model" => "test",
      "stream" => true,
      "messages" => [
        %{
          "role" => "user",
          "content" => [%{"type" => "image_url", "image_url" => %{"url" => data_url}}]
        }
      ]
    }
  end

  defp request_path(Responses), do: "/responses"
  defp request_path(AnthropicMessages), do: "/messages"
  defp request_path(GoogleInteractions), do: "/interactions"
  defp request_path(_chat_provider), do: "/chat/completions"

  defp completion_event(adapter) do
    event =
      case adapter do
        Responses ->
          %{
            "type" => "response.completed",
            "response" => %{"id" => "resp_1", "status" => "completed", "output" => []}
          }

        AnthropicMessages ->
          %{"type" => "message_stop"}

        GoogleInteractions ->
          %{
            "event_type" => "interaction.completed",
            "interaction" => %{"id" => "interaction_1", "status" => "completed", "steps" => []}
          }

        _chat_provider ->
          %{"choices" => [%{"delta" => %{"content" => "Done"}, "finish_reason" => "stop"}]}
      end

    "data: " <> Jason.encode!(event) <> "\n\ndata: [DONE]\n\n"
  end
end
