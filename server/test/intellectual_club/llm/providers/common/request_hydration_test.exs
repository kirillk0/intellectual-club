Code.require_file("../image_mapper_dummy_test.exs", __DIR__)

defmodule IntellectualClub.Llm.Providers.Common.RequestHydrationTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageStep, ChatMessageStepRequestFile}
  alias IntellectualClub.Files
  alias IntellectualClub.Generation.RequestImages
  alias IntellectualClub.Llm.Providers.AnthropicMessages
  alias IntellectualClub.Llm.Providers.Common.PreparedRequest
  alias IntellectualClub.Llm.Providers.Common.RequestHydration
  alias IntellectualClub.Llm.Providers.ImageMapperDummy
  alias IntellectualClub.Llm.Providers.GoogleInteractions
  alias IntellectualClub.Llm.Providers.NvidiaBuildChatCompletion
  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion
  alias IntellectualClub.Llm.Providers.Responses
  alias IntellectualClub.Llm.Providers.ResponsesWss
  alias IntellectualClub.Llm.Providers.ResponsesWss.Session

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
      ResponsesWss,
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

      assert {:ok, _hydrated} =
               RequestHydration.hydrate(prepared, step.id, &adapter.map_request_images/3,
                 on_cache: fn cache -> send(parent, {:initial_cache, cache}) end,
                 provider: :label_only
               )

      assert_receive {:initial_cache, cache}
      assert map_size(cache) == 1

      if adapter == Responses do
        dummy_request = %{
          "packets" => [
            %{
              "kind" => "packet",
              "parts" => [
                %{"kind" => "picture", "mime" => "image/png", "attachment" => base64_marker}
              ]
            }
          ]
        }

        assert {:ok, dummy_wire} =
                 RequestHydration.hydrate(
                   dummy_request,
                   step.id,
                   &ImageMapperDummy.map_request_images/3,
                   provider: :never_registered_provider
                 )

        assert get_in(dummy_wire, ["packets", Access.at(0), "parts", Access.at(0), "attachment"]) ==
                 "image/png:" <> encoded_image
      end

      handler_id = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:intellectual_club, :generation, :request_image_cache],
          &__MODULE__.cache_event/4,
          parent
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      http_handler = fn conn, _opts ->
        assert conn.method == "POST"
        assert conn.request_path == request_path(adapter)
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == wire
        send(parent, {:wire_request, adapter, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, completion_event(adapter))
      end

      handler = fn conn, opts ->
        if Plug.Conn.get_req_header(conn, "upgrade") == ["websocket"] do
          send(parent, :websocket_upgrade_attempted)
          Plug.Conn.send_resp(conn, 400, "WebSocket unavailable")
        else
          http_handler.(conn, opts)
        end
      end

      server =
        start_supervised!(
          Supervisor.child_spec({Bandit, plug: handler, scheme: :http, port: 0},
            id: {Bandit, adapter}
          )
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)
      context = Map.put(context, :provider_base_url, "http://127.0.0.1:#{port}")
      session = if adapter == ResponsesWss, do: start_supervised!({Session, context})

      assert :ok =
               adapter.stream_generate(
                 %{
                   context: context,
                   request_payload: prepared,
                   request_step_id: step.id,
                   provider_session: session,
                   image_cache: Map.put(cache, :unused, %{}),
                   image_cache_update: fn updated ->
                     send(parent, {:updated_cache, adapter, updated})
                   end,
                   timeout_ms: 1_000
                 },
                 fn event -> send(parent, {:provider_event, event}) end
               )

      assert_receive {:wire_request, ^adapter, ^wire}
      assert_receive {:updated_cache, ^adapter, ^cache}
      assert_receive {:cache_event, %{hit: 1}}
      refute_receive {:cache_event, %{loaded_bytes: _}}, 0
      refute_receive {:cache_event, %{encoded_bytes: _}}, 0
      refute_receive {Session, _ref, _cache}, 0
      :telemetry.detach(handler_id)

      if adapter == ResponsesWss do
        assert_receive :websocket_upgrade_attempted
        assert_receive {:updated_cache, ^adapter, ^cache}
      end

      assert_receive {:provider_event, {:response_complete, %{raw_request: ^prepared}}}
      refute_receive {:provider_event, {:response_error, _}}, 0
      refute_receive {:provider_event, {:trace, {:set_step_raw_request, _}}}, 0

      persisted = Ash.get!(ChatMessageStep, step.id, actor: actor, load: [:raw_request])
      assert persisted.raw_request == prepared
    end
  end

  test "cold WSS hydration is reused by HTTP fallback without waiting for the Worker cache" do
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
    data_url = "data:image/png;base64," <> encoded_image
    {:ok, file} = Files.create_from_binary("cold-request.png", "image/png", image)
    marker = RequestImages.marker(to_string(file.external_id), "image/png")

    context = %{
      provider_type: Responses.type(),
      provider_auth_method: "api_key",
      provider_api_key: "test-key",
      owner_id: actor.id,
      chat_id: chat.id
    }

    prepared = PreparedRequest.prepare(Responses, image_request(Responses, marker, nil), context)
    wire = PreparedRequest.prepare(Responses, image_request(Responses, data_url, nil), context)

    step =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_id: message.id,
          sequence: 1,
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

    for adapter <- [Responses, ResponsesWss] do
      handler_id = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:intellectual_club, :generation, :request_image_cache],
          &__MODULE__.cache_event/4,
          parent
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      handler = fn conn, _opts ->
        if Plug.Conn.get_req_header(conn, "upgrade") == ["websocket"] do
          send(parent, :websocket_upgrade_attempted)
          Plug.Conn.send_resp(conn, 400, "WebSocket unavailable")
        else
          assert conn.method == "POST"
          assert conn.request_path == "/responses"
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body) == wire
          send(parent, :http_fallback_sent)

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, completion_event(adapter))
        end
      end

      server =
        start_supervised!(
          Supervisor.child_spec({Bandit, plug: handler, scheme: :http, port: 0},
            id: {Bandit, adapter}
          )
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)

      context =
        Map.merge(context, %{
          provider_type: adapter.type(),
          provider_base_url: "ws://127.0.0.1:#{port}"
        })

      session =
        start_supervised!(Supervisor.child_spec({Session, context}, id: {Session, adapter}))

      # Queue Worker updates without processing them until the stream has finished.
      on_cache =
        if adapter == Responses,
          do: fn cache -> send(parent, {:worker_cache_update, cache}) end

      log =
        ExUnit.CaptureLog.capture_log([level: :warning, metadata: :all], fn ->
          assert :ok =
                   adapter.stream_generate(
                     %{
                       context: context,
                       request_payload: prepared,
                       request_step_id: step.id,
                       provider_session: session,
                       image_cache: %{},
                       image_cache_update: on_cache,
                       timeout_ms: 1_000,
                       connect_timeout_ms: 1_000
                     },
                     fn event -> send(parent, {:provider_event, event}) end
                   )
        end)

      assert_receive :websocket_upgrade_attempted
      assert_receive :http_fallback_sent
      assert_receive {:cache_event, %{loaded_bytes: loaded_bytes}}
      assert loaded_bytes == byte_size(image)
      assert_receive {:cache_event, %{miss: 1, encoded_bytes: encoded_bytes}}
      assert encoded_bytes == byte_size(data_url)
      assert_receive {:cache_event, %{hit: 1}}
      refute_receive {:cache_event, _}, 0
      refute_receive {Session, _ref, _cache}, 0
      :telemetry.detach(handler_id)

      if adapter == Responses do
        assert_receive {:worker_cache_update, cache}
        assert map_size(cache) == 1
        assert_receive {:worker_cache_update, ^cache}
      else
        refute_receive {:worker_cache_update, _}, 0
      end

      assert log =~ "Responses WebSocket transport fell back to HTTP"
      assert log =~ "fallback_reason=websocket_handshake_failed"
      refute log =~ encoded_image
      refute log =~ "data:image"
      refute log =~ "image_cache"
      assert_receive {:provider_event, {:response_complete, %{raw_request: ^prepared}}}
      refute_receive {:provider_event, {:response_error, _}}, 0
      refute_receive {:provider_event, {:trace, {:set_step_raw_request, _}}}, 0
    end

    persisted = Ash.get!(ChatMessageStep, step.id, actor: actor, load: [:raw_request])
    assert persisted.raw_request == prepared
  end

  test "mapper exceptions retain the logical request and provider label" do
    request = %{"opaque" => true}
    mapper = fn _request, _acc, _map -> raise "Provider mapper failed" end

    assert {:error, error} =
             RequestHydration.hydrate(request, nil, mapper, provider: :new_provider)

    assert error.provider == :new_provider
    assert error.raw_request == request
    assert error.raw_response == nil
    assert error.retryable == false
    assert error.error_kind == "request_hydration"
    assert error.error_text =~ "Provider mapper failed"
  end

  def cache_event(_event, measurements, _metadata, parent),
    do: send(parent, {:cache_event, measurements})

  defp image_request(adapter, data_url, _base64) when adapter in [Responses, ResponsesWss] do
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

  defp request_path(adapter) when adapter in [Responses, ResponsesWss], do: "/responses"
  defp request_path(AnthropicMessages), do: "/messages"
  defp request_path(GoogleInteractions), do: "/interactions"
  defp request_path(_chat_provider), do: "/chat/completions"

  defp completion_event(adapter) do
    event =
      case adapter do
        adapter when adapter in [Responses, ResponsesWss] ->
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
