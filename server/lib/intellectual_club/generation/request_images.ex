defmodule IntellectualClub.Generation.RequestImages do
  @moduledoc """
  Compacts provider-native request images into stable file markers.

  Materialization pins one logical file per image reference and request step. Hydration
  resolves only those step-local bindings and restores provider wire encodings without
  changing the compact request kept for tracing and continuation comparisons.
  """

  require Ash.Query
  require Logger

  alias IntellectualClub.Chat.{ContentFiles, ChatMessageStep, ChatMessageStepRequestFile}

  alias IntellectualClub.Files
  alias IntellectualClub.Generation.RequestImages.{StagedBindings, Walker}
  alias IntellectualClub.Tools.ExecutionContext

  @marker_key "$intellectual_club_file"
  @version 1
  @max_edge_px 2_000
  @identity_variant "identity:v1"
  @thumbnail_variant "thumbnail:max-edge=2000:preserve-format:v1"
  @legacy_exact_variant "legacy_exact:v1"
  @fit_rendition %{
    "kind" => "fit",
    "max_edge_px" => @max_edge_px,
    "format" => "preserve"
  }
  @legacy_exact_rendition %{
    "kind" => "legacy_exact",
    "format" => "preserve"
  }
  @invalid_image_fallback "[Image omitted: attached file could not be validated as an image.]"
  @resize_fallback "[Image omitted: attached image exceeded the native image size limit and could not be resized.]"

  @type encoding :: :data_url | :base64 | String.t()

  @doc """
  Builds a v1 compact marker. The canonical file UUID is also the initial stable
  reference key.
  """
  @spec marker(String.t(), String.t(), encoding()) :: map()
  def marker(source_file_external_id, mime_type, encoding \\ :data_url)
      when is_binary(source_file_external_id) and is_binary(mime_type) do
    marker_with_rendition(
      source_file_external_id,
      mime_type,
      encoding,
      @fit_rendition
    )
  end

  @doc """
  Builds a v1 marker for replaying the exact image bytes captured in a legacy raw request.

  Unlike the normal fit rendition, this marker may reference an image larger than the current
  native image limit. It must resolve to a step-local `legacy_exact:v1` binding and is never
  reconstructed from the canonical source file.
  """
  @spec legacy_exact_marker(String.t(), String.t(), encoding()) :: map()
  def legacy_exact_marker(source_file_external_id, mime_type, encoding \\ :data_url)
      when is_binary(source_file_external_id) and is_binary(mime_type) do
    marker_with_rendition(
      source_file_external_id,
      mime_type,
      encoding,
      @legacy_exact_rendition
    )
  end

  defp marker_with_rendition(source_file_external_id, mime_type, encoding, rendition) do
    %{
      @marker_key => %{
        "version" => @version,
        "reference_key" => source_file_external_id,
        "source_file_external_id" => source_file_external_id,
        "rendition" => rendition,
        "encoding" => normalize_encoding(encoding),
        "mime_type" => normalize_mime_type(mime_type)
      }
    }
  end

  @doc """
  Pins all v1 image markers to `step_id`, stores the compact request on the step,
  and removes bindings which are no longer referenced by that request.
  """
  @spec materialize_and_persist(map(), integer()) :: {:ok, map()} | {:error, term()}
  def materialize_and_persist(raw_request, step_id)
      when is_map(raw_request) and is_integer(step_id),
      do: do_materialize_and_persist(step_id, raw_request)

  @spec materialize_and_persist(integer(), map()) :: {:ok, map()} | {:error, term()}
  def materialize_and_persist(step_id, raw_request)
      when is_integer(step_id) and is_map(raw_request),
      do: do_materialize_and_persist(step_id, raw_request)

  def materialize_and_persist(_step_id, _raw_request),
    do: {:error, :invalid_materialization_arguments}

  defp do_materialize_and_persist(step_id, raw_request) do
    with {:ok, step} <- load_step(step_id),
         {:ok, bindings} <- bindings_for_step(step_id) do
      chat_scope_ids =
        ContentFiles.handoff_chat_scope_ids(step.chat_message.chat_id, step.owner_id)

      state = %{
        step: step,
        chat_scope_ids: chat_scope_ids,
        owner_id: step.owner_id,
        bindings: Map.new(bindings, &{to_string(&1.reference_key), &1}),
        results: %{},
        active_refs: MapSet.new(),
        created_binding_ids: [],
        error: nil
      }

      {compact_request, state} =
        Walker.map_images(raw_request, state, &materialize_block/4)

      finish_materialization(compact_request, state)
    end
  end

  @doc """
  Resolves compact markers through bindings owned by `step_id` and creates the
  provider wire payload. Legacy strings and markers outside supported image paths
  are left untouched.
  """
  @spec hydrate(map(), integer() | nil) :: {:ok, map()} | {:error, term()}
  def hydrate(raw_request, step_id) when is_map(raw_request) and is_integer(step_id) do
    with {:ok, bindings} <- bindings_for_step(step_id) do
      hydrate_with_bindings(raw_request, bindings)
    end
  end

  def hydrate(raw_request, nil) when is_map(raw_request),
    do: hydrate_with_bindings(raw_request, [])

  def hydrate(_raw_request, _step_id), do: {:error, :invalid_hydration_arguments}

  defp hydrate_with_bindings(raw_request, bindings) do
    state = %{
      bindings: Map.new(bindings, &{to_string(&1.reference_key), &1}),
      hydrated: %{},
      error: nil
    }

    {wire_request, state} = Walker.map_images(raw_request, state, &hydrate_block/4)

    case state.error do
      nil -> {:ok, wire_request}
      error -> {:error, error}
    end
  end

  @doc """
  Duplicates all request-file bindings from one existing step to another.
  """
  @spec clone_bindings(integer(), integer()) :: :ok | {:error, term()}
  def clone_bindings(source_step_id, target_step_id)
      when is_integer(source_step_id) and is_integer(target_step_id) do
    with {:ok, staged} <- stage_bindings(source_step_id) do
      case attach_staged_bindings(staged, target_step_id) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, error_with_cleanup(reason, discard_staged_bindings(staged))}
      end
    end
  end

  def clone_bindings(_source_step_id, _target_step_id), do: {:error, :invalid_step_id}

  @doc """
  Duplicates logical files before their source step is destructively removed.
  """
  @spec stage_bindings(integer()) :: {:ok, StagedBindings.t()} | {:error, term()}
  def stage_bindings(source_step_id) when is_integer(source_step_id) do
    with {:ok, bindings} <- bindings_for_step(source_step_id) do
      Enum.reduce_while(bindings, {:ok, []}, fn binding, {:ok, staged} ->
        case Files.duplicate_file(binding.file_id) do
          {:ok, duplicate} ->
            item = %{
              file_id: duplicate.id,
              reference_key: to_string(binding.reference_key),
              source_file_external_id: to_string(binding.source_file_external_id),
              variant_key: binding.variant_key
            }

            {:cont, {:ok, [item | staged]}}

          {:error, reason} ->
            error = {:stage_binding_failed, binding.id, reason}
            {:halt, {:error, error_with_cleanup(error, cleanup_staged_files(staged))}}
        end
      end)
      |> case do
        {:ok, staged} -> {:ok, %StagedBindings{items: Enum.reverse(staged)}}
        {:error, _reason} = error -> error
      end
    end
  end

  def stage_bindings(_source_step_id), do: {:error, :invalid_step_id}

  @doc """
  Attaches previously staged logical files to a replacement step. The staged
  value is consumed whether this succeeds or fails.
  """
  @spec attach_staged_bindings(StagedBindings.t(), integer()) :: :ok | {:error, term()}
  def attach_staged_bindings(%StagedBindings{items: items}, target_step_id)
      when is_integer(target_step_id) do
    attach_staged_items(items, target_step_id, [], cleanup_on_error?: true)
  end

  def attach_staged_bindings(_staged, _target_step_id), do: {:error, :invalid_staged_bindings}

  @doc """
  Attaches staged files inside a caller-owned database transaction.

  This variant never destroys files or compensates partial bindings on error. The
  caller must raise or otherwise roll back the surrounding transaction.
  """
  @spec attach_staged_bindings_transactional(StagedBindings.t(), integer()) ::
          :ok | {:error, term()}
  def attach_staged_bindings_transactional(%StagedBindings{items: items}, target_step_id)
      when is_integer(target_step_id) do
    attach_staged_items(items, target_step_id, [], cleanup_on_error?: false)
  end

  def attach_staged_bindings_transactional(_staged, _target_step_id),
    do: {:error, :invalid_staged_bindings}

  @doc """
  Deletes logical files from an unused or transaction-rolled-back staged value.
  Files which are already owned by a binding are preserved.
  """
  @spec discard_staged_bindings(StagedBindings.t()) :: :ok | {:error, term()}
  def discard_staged_bindings(%StagedBindings{items: items}) do
    cleanup_staged_files(items)
  end

  def discard_staged_bindings(_staged), do: {:error, :invalid_staged_bindings}

  defp materialize_block(_shape, block, _marker, %{error: error} = state)
       when not is_nil(error),
       do: {block, state}

  defp materialize_block(shape, block, marker, state) do
    with {:ok, descriptor} <- validate_marker(marker, shape),
         :ok <- validate_repeated_descriptor(state.results, descriptor),
         {:ok, result, state} <- materialize_descriptor(descriptor, state) do
      case result do
        %{status: :ok, mime_type: mime_type} ->
          compact_marker = put_marker_mime(marker, mime_type)
          result = Map.put(result, :source_file_external_id, descriptor.source_file_external_id)

          {
            put_compact_marker(shape, block, compact_marker, mime_type),
            %{
              state
              | results: Map.put(state.results, descriptor.reference_key, result),
                active_refs: MapSet.put(state.active_refs, descriptor.reference_key)
            }
          }

        %{status: :fallback, text: text} ->
          result = Map.put(result, :source_file_external_id, descriptor.source_file_external_id)

          {
            fallback_block(shape, block, text),
            %{state | results: Map.put(state.results, descriptor.reference_key, result)}
          }
      end
    else
      {:error, reason, failed_state} ->
        {block, %{failed_state | error: reason}}

      {:error, reason} ->
        {block, %{state | error: reason}}
    end
  end

  defp materialize_descriptor(descriptor, state) do
    case Map.fetch(state.results, descriptor.reference_key) do
      {:ok, result} ->
        {:ok, result, state}

      :error ->
        case Map.get(state.bindings, descriptor.reference_key) do
          %ChatMessageStepRequestFile{} = binding ->
            materialize_existing_binding(binding, descriptor, state)

          nil ->
            materialize_new_binding(descriptor, state)
        end
    end
  end

  defp materialize_existing_binding(binding, descriptor, state) do
    case validate_binding_descriptor(binding, descriptor) do
      :ok ->
        case load_valid_image(binding.file_id) do
          {:ok, image} ->
            if rendition_accepts_image?(descriptor, image) do
              {:ok, %{status: :ok, mime_type: image.mime_type}, state}
            else
              {:ok, %{status: :fallback, text: @invalid_image_fallback}, state}
            end

          {:error, reason} ->
            if fallback_image_error?(reason) do
              {:ok, %{status: :fallback, text: @invalid_image_fallback}, state}
            else
              {:error, {:load_request_image_binding_failed, binding.id, reason}, state}
            end
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp materialize_new_binding(descriptor, state) do
    case reusable_binding(descriptor, state) do
      {:ok, binding} ->
        duplicate_and_bind(binding.file_id, binding.variant_key, descriptor, state)

      :not_found when descriptor.rendition_kind == :legacy_exact ->
        {:ok, %{status: :fallback, text: @invalid_image_fallback}, state}

      :not_found ->
        materialize_canonical(descriptor, state)

      {:error, reason} ->
        {:error, {:find_reusable_request_file_failed, reason}, state}
    end
  end

  defp materialize_canonical(descriptor, state) do
    context = %ExecutionContext{
      owner_id: state.owner_id,
      chat_id: state.step.chat_message.chat_id,
      message_id: state.step.chat_message_id,
      assistant_message_id: state.step.chat_message_id,
      step_id: state.step.id,
      available_file_external_ids: []
    }

    case ContentFiles.load_payload_for_execution(descriptor.source_file_external_id, context) do
      {:ok, {_content, file, payload}} ->
        materialize_canonical_payload(file, payload, descriptor, state)

      {:error, reason} when reason in [:not_found, :file_not_found, :payload_not_found] ->
        {:ok, %{status: :fallback, text: @invalid_image_fallback}, state}

      {:error, reason} ->
        {:error, {:load_canonical_request_image_failed, reason}, state}
    end
  end

  defp materialize_canonical_payload(file, payload, descriptor, state) do
    case validate_image_payload(file, payload) do
      {:ok, image} when max(image.width, image.height) <= @max_edge_px ->
        duplicate_and_bind(file.id, @identity_variant, descriptor, state)

      {:ok, image} ->
        case resize_image_payload(image.payload, image.mime_type) do
          {:ok, resized_payload, resized_mime_type} ->
            filename = rendition_filename(file, descriptor.reference_key, resized_mime_type)

            case Files.create_from_binary(filename, resized_mime_type, resized_payload) do
              {:ok, resized_file} ->
                bind_materialized_file(
                  resized_file.id,
                  @thumbnail_variant,
                  descriptor,
                  state
                )

              {:error, reason} ->
                {:error, {:create_thumbnail_file_failed, reason}, state}
            end

          {:error, _reason} ->
            {:ok, %{status: :fallback, text: @resize_fallback}, state}
        end

      {:error, _reason} ->
        {:ok, %{status: :fallback, text: @invalid_image_fallback}, state}
    end
  end

  defp duplicate_and_bind(source_file_id, variant_key, descriptor, state) do
    case Files.duplicate_file(source_file_id) do
      {:ok, file} ->
        bind_materialized_file(file.id, variant_key, descriptor, state)

      {:error, reason} ->
        {:error, {:duplicate_request_file_failed, reason}, state}
    end
  end

  defp bind_materialized_file(file_id, variant_key, descriptor, state) do
    attrs = %{
      chat_message_step_id: state.step.id,
      file_id: file_id,
      reference_key: descriptor.reference_key,
      source_file_external_id: descriptor.source_file_external_id,
      variant_key: variant_key
    }

    case create_binding(attrs) do
      {:ok, binding} ->
        with {:ok, image} <- load_valid_image(binding.file_id) do
          next_state = %{
            state
            | bindings: Map.put(state.bindings, descriptor.reference_key, binding),
              created_binding_ids: [binding.id | state.created_binding_ids]
          }

          {:ok, %{status: :ok, mime_type: image.mime_type}, next_state}
        else
          {:error, reason} ->
            error = {:created_binding_payload_invalid, reason}
            {:error, error_with_cleanup(error, destroy_binding(binding)), state}
        end

      {:error, create_reason} ->
        case binding_for_reference(state.step.id, descriptor.reference_key) do
          {:ok, %ChatMessageStepRequestFile{} = winner} ->
            case delete_unbound_file(file_id) do
              :ok ->
                materialize_existing_binding(winner, descriptor, state)

              {:error, cleanup_reason} ->
                {:error, {:request_file_conflict_cleanup_failed, create_reason, cleanup_reason},
                 state}
            end

          {:ok, nil} ->
            error = {:create_request_file_binding_failed, create_reason}
            {:error, error_with_cleanup(error, delete_unbound_file(file_id)), state}

          {:error, lookup_reason} ->
            error =
              {:request_file_conflict_lookup_failed, create_reason, lookup_reason}

            {:error, error_with_cleanup(error, delete_unbound_file(file_id)), state}
        end
    end
  end

  defp finish_materialization(_compact_request, %{error: error} = state)
       when not is_nil(error) do
    {:error, error_with_cleanup(error, compensate_created_bindings(state.created_binding_ids))}
  end

  defp finish_materialization(compact_request, state) do
    case persist_compact_request(state.step, compact_request) do
      {:ok, _step} ->
        case remove_stale_bindings(state.step.id, state.active_refs) do
          :ok ->
            {:ok, compact_request}

          {:error, reason} ->
            Logger.warning(
              "Compact request persisted but stale request files could not be removed " <>
                "step_id=#{state.step.id} reason=#{inspect(reason)}"
            )

            {:ok, compact_request}
        end

      {:error, reason} ->
        error = {:persist_compact_request_failed, reason}

        {:error,
         error_with_cleanup(error, compensate_created_bindings(state.created_binding_ids))}
    end
  end

  defp hydrate_block(_shape, block, _marker, %{error: error} = state) when not is_nil(error),
    do: {block, state}

  defp hydrate_block(shape, block, marker, state) do
    with {:ok, descriptor} <- validate_marker(marker, shape),
         {:ok, image, state} <- hydrated_image(descriptor, state) do
      {put_wire_image(shape, block, image), state}
    else
      {:error, reason, failed_state} -> {block, %{failed_state | error: reason}}
      {:error, reason} -> {block, %{state | error: reason}}
    end
  end

  defp hydrated_image(descriptor, state) do
    case Map.fetch(state.hydrated, descriptor.reference_key) do
      {:ok, image} ->
        case Map.get(state.bindings, descriptor.reference_key) do
          %ChatMessageStepRequestFile{} = binding ->
            case validate_binding_descriptor(binding, descriptor) do
              :ok -> {:ok, image, state}
              {:error, reason} -> {:error, reason, state}
            end

          nil ->
            {:error, {:request_image_binding_not_found, descriptor.reference_key}, state}
        end

      :error ->
        with %ChatMessageStepRequestFile{} = binding <-
               Map.get(state.bindings, descriptor.reference_key),
             :ok <- validate_binding_descriptor(binding, descriptor),
             {:ok, image} <- load_valid_image(binding.file_id),
             true <- rendition_accepts_image?(descriptor, image) do
          {:ok, image,
           %{state | hydrated: Map.put(state.hydrated, descriptor.reference_key, image)}}
        else
          nil -> {:error, {:request_image_binding_not_found, descriptor.reference_key}, state}
          false -> {:error, {:request_image_binding_oversized, descriptor.reference_key}, state}
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  defp validate_marker(marker, shape) when is_map(marker) do
    reference_key = Map.get(marker, "reference_key")
    source_file_external_id = Map.get(marker, "source_file_external_id")
    rendition = Map.get(marker, "rendition")
    rendition_kind = rendition_kind(rendition)
    encoding = Map.get(marker, "encoding")
    mime_type = normalize_mime_type(Map.get(marker, "mime_type"))

    expected_encoding = if shape in [:responses, :openrouter], do: "data_url", else: "base64"

    cond do
      Map.get(marker, "version") != @version ->
        {:error, {:unsupported_request_image_marker_version, Map.get(marker, "version")}}

      not uuid?(reference_key) ->
        {:error, :invalid_request_image_reference_key}

      not uuid?(source_file_external_id) ->
        {:error, :invalid_request_image_source_file_external_id}

      is_nil(rendition_kind) ->
        {:error, :unsupported_request_image_rendition}

      encoding != expected_encoding ->
        {:error, {:invalid_request_image_encoding, shape, encoding}}

      not image_mime_type?(mime_type) ->
        {:error, :invalid_request_image_mime_type}

      true ->
        {:ok,
         %{
           reference_key: reference_key,
           source_file_external_id: source_file_external_id,
           mime_type: mime_type,
           rendition_kind: rendition_kind
         }}
    end
  end

  defp validate_repeated_descriptor(results, descriptor) do
    case Map.get(results, descriptor.reference_key) do
      nil ->
        :ok

      %{source_file_external_id: source_file_external_id}
      when source_file_external_id != descriptor.source_file_external_id ->
        {:error, {:conflicting_request_image_marker, descriptor.reference_key}}

      _result ->
        :ok
    end
  end

  defp validate_binding_descriptor(binding, descriptor) do
    cond do
      to_string(binding.source_file_external_id) != descriptor.source_file_external_id ->
        {:error, {:request_image_binding_source_mismatch, descriptor.reference_key}}

      binding.variant_key not in allowed_binding_variants(descriptor) ->
        {:error, {:unsupported_request_image_binding_variant, binding.variant_key}}

      true ->
        :ok
    end
  end

  defp load_valid_image(file_id) do
    with {:ok, {file, payload}} <- Files.load_payload(file_id) do
      validate_image_payload(file, payload)
    end
  end

  defp validate_image_payload(file, payload) do
    with true <- is_binary(payload),
         {mime_type, width, height, _variant}
         when is_binary(mime_type) and is_integer(width) and is_integer(height) and width > 0 and
                height > 0 <- ExImageInfo.info(payload),
         true <- image_mime_type?(mime_type) do
      {:ok,
       %{
         file: file,
         payload: payload,
         mime_type: normalize_mime_type(mime_type),
         width: width,
         height: height
       }}
    else
      false -> {:error, :not_an_image}
      nil -> {:error, :invalid_image_payload}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_image_payload, other}}
    end
  end

  defp fallback_image_error?(reason)
       when reason in [:payload_not_found, :invalid_image_payload, :not_an_image],
       do: true

  defp fallback_image_error?({:invalid_image_payload, _detail}), do: true
  defp fallback_image_error?(_reason), do: false

  defp resize_image_payload(payload, mime_type) do
    try do
      with {:ok, suffix} <- image_suffix(mime_type),
           {:ok, image} <- Image.from_binary(payload),
           {:ok, resized_image} <- Image.thumbnail(image, @max_edge_px, resize: :down),
           {:ok, resized_payload} when is_binary(resized_payload) <-
             Image.write(resized_image, :memory, suffix: suffix),
           {resized_mime_type, width, height, _variant}
           when is_integer(width) and is_integer(height) <- ExImageInfo.info(resized_payload),
           true <- max(width, height) <= @max_edge_px do
        {:ok, resized_payload, normalize_mime_type(resized_mime_type)}
      else
        false -> {:error, :resized_image_exceeds_limit}
        nil -> {:error, :resized_image_invalid}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, value -> {:error, {kind, value}}
    end
  end

  defp load_step(step_id) do
    ChatMessageStep
    |> Ash.Query.filter(id == ^step_id)
    |> Ash.Query.select([:id, :owner_id, :chat_message_id, :raw_request])
    |> Ash.Query.load(chat_message: [:id, :chat_id])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %ChatMessageStep{} = step} -> {:ok, step}
      {:ok, nil} -> {:error, :step_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bindings_for_step(step_id) do
    ChatMessageStepRequestFile
    |> Ash.Query.filter(chat_message_step_id == ^step_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(:file)
    |> Ash.read(authorize?: false)
  end

  defp binding_for_reference(step_id, reference_key) do
    ChatMessageStepRequestFile
    |> Ash.Query.filter(chat_message_step_id == ^step_id and reference_key == ^reference_key)
    |> Ash.Query.load(:file)
    |> Ash.read_one(authorize?: false)
  end

  defp reusable_binding(descriptor, state) do
    allowed_variants = allowed_binding_variants(descriptor)

    ChatMessageStepRequestFile
    |> Ash.Query.filter(
      reference_key == ^descriptor.reference_key and
        source_file_external_id == ^descriptor.source_file_external_id and
        variant_key in ^allowed_variants and
        chat_message_step_id != ^state.step.id and
        chat_message_step.owner_id == ^state.owner_id and
        chat_message_step.chat_message.chat_id in ^state.chat_scope_ids
    )
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(:file)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %ChatMessageStepRequestFile{} = binding} ->
        with :ok <- validate_binding_descriptor(binding, descriptor),
             {:ok, image} <- load_valid_image(binding.file_id),
             true <- rendition_accepts_image?(descriptor, image) do
          {:ok, binding}
        else
          false ->
            :not_found

          {:error, reason}
          when reason in [:payload_not_found, :invalid_image_payload, :not_an_image] ->
            :not_found

          {:error, {:invalid_image_payload, _detail}} ->
            :not_found

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, nil} ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_binding(attrs) do
    ChatMessageStepRequestFile
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create(authorize?: false)
  end

  defp persist_compact_request(%ChatMessageStep{raw_request: raw_request} = step, compact_request)
       when raw_request == compact_request,
       do: {:ok, step}

  defp persist_compact_request(step, compact_request) do
    step
    |> Ash.Changeset.for_update(:update, %{raw_request: compact_request}, authorize?: false)
    |> Ash.update(authorize?: false)
  end

  defp remove_stale_bindings(step_id, active_refs) do
    with {:ok, bindings} <- bindings_for_step(step_id) do
      bindings
      |> Enum.reject(&MapSet.member?(active_refs, to_string(&1.reference_key)))
      |> Enum.reduce_while(:ok, fn binding, :ok ->
        case destroy_binding(binding) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp compensate_created_bindings(binding_ids) do
    errors =
      Enum.reduce(binding_ids, [], fn binding_id, errors ->
        ChatMessageStepRequestFile
        |> Ash.Query.filter(id == ^binding_id)
        |> Ash.read_one(authorize?: false)
        |> case do
          {:ok, nil} ->
            errors

          {:ok, %ChatMessageStepRequestFile{} = binding} ->
            case destroy_binding(binding) do
              :ok -> errors
              {:error, reason} -> [{binding_id, {:destroy_failed, reason}} | errors]
            end

          {:error, reason} ->
            [{binding_id, {:load_failed, reason}} | errors]
        end
      end)

    cleanup_errors_result(:created_binding_compensation_failed, errors)
  end

  defp destroy_binding(binding) do
    case Ash.destroy(binding, authorize?: false) do
      :ok -> :ok
      {:ok, _record} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp attach_staged_items([], _target_step_id, _attached_binding_ids, _opts), do: :ok

  defp attach_staged_items([item | rest], target_step_id, attached_binding_ids, opts) do
    attrs = Map.put(item, :chat_message_step_id, target_step_id)
    cleanup_on_error? = Keyword.fetch!(opts, :cleanup_on_error?)

    case create_binding(attrs) do
      {:ok, binding} ->
        attach_staged_items(rest, target_step_id, [binding.id | attached_binding_ids], opts)

      {:error, reason} ->
        case {cleanup_on_error?, binding_for_reference(target_step_id, item.reference_key)} do
          {true, {:ok, %ChatMessageStepRequestFile{} = winner}} ->
            if staged_binding_matches?(winner, item) do
              case delete_unbound_file(item.file_id) do
                :ok ->
                  attach_staged_items(rest, target_step_id, attached_binding_ids, opts)

                {:error, cleanup_reason} ->
                  attach_staged_failure(
                    {:discard_duplicate_staged_file_failed, item.reference_key, cleanup_reason},
                    attached_binding_ids,
                    [item | rest]
                  )
              end
            else
              attach_staged_failure(
                {:conflicting_staged_binding, item.reference_key, winner.source_file_external_id,
                 winner.variant_key},
                attached_binding_ids,
                [item | rest]
              )
            end

          {true, {:ok, nil}} ->
            attach_staged_failure(
              {:attach_staged_binding_failed, item.reference_key, reason},
              attached_binding_ids,
              [item | rest]
            )

          {true, {:error, lookup_reason}} ->
            attach_staged_failure(
              {:attach_staged_binding_lookup_failed, item.reference_key, reason, lookup_reason},
              attached_binding_ids,
              [item | rest]
            )

          {false, _lookup_result} ->
            {:error, {:attach_staged_binding_failed, item.reference_key, reason}}
        end
    end
  end

  defp staged_binding_matches?(binding, item) do
    to_string(binding.source_file_external_id) == to_string(item.source_file_external_id) and
      binding.variant_key == item.variant_key
  end

  defp attach_staged_failure(error, attached_binding_ids, staged_items) do
    cleanup_results = [
      compensate_created_bindings(attached_binding_ids),
      cleanup_staged_files(staged_items)
    ]

    {:error, error_with_cleanups(error, cleanup_results)}
  end

  defp cleanup_staged_files(items) do
    errors =
      Enum.reduce(items, [], fn item, errors ->
        file_id = Map.get(item, :file_id)

        if is_integer(file_id) do
          case file_bound?(file_id) do
            {:ok, true} ->
              errors

            {:ok, false} ->
              case delete_unbound_file(file_id) do
                :ok -> errors
                {:error, reason} -> [{file_id, reason} | errors]
              end

            {:error, reason} ->
              [{file_id, {:binding_lookup_failed, reason}} | errors]
          end
        else
          [{file_id, :invalid_file_id} | errors]
        end
      end)

    cleanup_errors_result(:staged_file_cleanup_failed, errors)
  end

  defp file_bound?(file_id) do
    ChatMessageStepRequestFile
    |> Ash.Query.filter(file_id == ^file_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %ChatMessageStepRequestFile{}} -> {:ok, true}
      {:ok, nil} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_unbound_file(file_id) do
    case Files.delete_file_and_maybe_payload(file_id) do
      :ok -> :ok
      {:error, reason} -> {:error, {:delete_unbound_request_file_failed, file_id, reason}}
    end
  end

  defp cleanup_errors_result(_kind, []), do: :ok

  defp cleanup_errors_result(kind, errors),
    do: {:error, {kind, Enum.reverse(errors)}}

  defp error_with_cleanup(error, :ok), do: error

  defp error_with_cleanup(error, {:error, cleanup_error}),
    do: {:request_image_cleanup_failed, error, cleanup_error}

  defp error_with_cleanups(error, cleanup_results) do
    cleanup_errors =
      Enum.flat_map(cleanup_results, fn
        :ok -> []
        {:error, cleanup_error} -> [cleanup_error]
      end)

    case cleanup_errors do
      [] -> error
      errors -> {:request_image_cleanup_failed, error, errors}
    end
  end

  defp put_compact_marker(:responses, block, marker, _mime_type) do
    Map.put(block, "image_url", %{@marker_key => marker})
  end

  defp put_compact_marker(:openrouter, block, marker, _mime_type) do
    Map.update!(block, "image_url", &Map.put(&1, "url", %{@marker_key => marker}))
  end

  defp put_compact_marker(:anthropic, block, marker, mime_type) do
    source =
      block
      |> Map.get("source", %{})
      |> Map.put("type", "base64")
      |> Map.put("media_type", mime_type)
      |> Map.put("data", %{@marker_key => marker})

    Map.put(block, "source", source)
  end

  defp put_compact_marker(:google, block, marker, mime_type) do
    block
    |> Map.put("mime_type", mime_type)
    |> Map.put("data", %{@marker_key => marker})
  end

  defp put_wire_image(:responses, block, image) do
    Map.put(block, "image_url", data_url(image))
  end

  defp put_wire_image(:openrouter, block, image) do
    Map.update!(block, "image_url", &Map.put(&1, "url", data_url(image)))
  end

  defp put_wire_image(:anthropic, block, image) do
    source =
      block
      |> Map.get("source", %{})
      |> Map.put("type", "base64")
      |> Map.put("media_type", image.mime_type)
      |> Map.put("data", Base.encode64(image.payload))

    Map.put(block, "source", source)
  end

  defp put_wire_image(:google, block, image) do
    block
    |> Map.put("mime_type", image.mime_type)
    |> Map.put("data", Base.encode64(image.payload))
  end

  defp fallback_block(:responses, _block, text), do: %{"type" => "input_text", "text" => text}
  defp fallback_block(:openrouter, _block, text), do: %{"type" => "text", "text" => text}
  defp fallback_block(:google, _block, text), do: %{"type" => "text", "text" => text}

  defp fallback_block(:anthropic, block, text) do
    case Map.get(block, "cache_control") do
      %{} = cache_control ->
        %{"type" => "text", "text" => text, "cache_control" => cache_control}

      _other ->
        %{"type" => "text", "text" => text}
    end
  end

  defp put_marker_mime(marker, mime_type), do: Map.put(marker, "mime_type", mime_type)

  defp rendition_kind(@fit_rendition), do: :fit
  defp rendition_kind(@legacy_exact_rendition), do: :legacy_exact
  defp rendition_kind(_rendition), do: nil

  defp allowed_binding_variants(%{rendition_kind: :fit}),
    do: [@identity_variant, @thumbnail_variant]

  defp allowed_binding_variants(%{rendition_kind: :legacy_exact}),
    do: [@legacy_exact_variant]

  defp rendition_accepts_image?(%{rendition_kind: :legacy_exact}, _image), do: true

  defp rendition_accepts_image?(%{rendition_kind: :fit}, image),
    do: max(image.width, image.height) <= @max_edge_px

  defp data_url(image) do
    "data:#{image.mime_type};base64," <> Base.encode64(image.payload)
  end

  defp rendition_filename(file, reference_key, mime_type) do
    basename =
      file.filename
      |> Path.basename()
      |> Path.rootname()
      |> case do
        "" -> "request-image-#{reference_key}"
        value -> value
      end

    basename <> image_suffix_for_filename(mime_type)
  end

  defp image_suffix(mime_type) do
    case normalize_mime_type(mime_type) do
      "image/png" -> {:ok, ".png"}
      "image/jpeg" -> {:ok, ".jpg"}
      "image/jpg" -> {:ok, ".jpg"}
      "image/webp" -> {:ok, ".webp"}
      "image/gif" -> {:ok, ".gif"}
      "image/tiff" -> {:ok, ".tif"}
      "image/x-tiff" -> {:ok, ".tif"}
      "image/avif" -> {:ok, ".avif"}
      "image/heif" -> {:ok, ".heif"}
      "image/heic" -> {:ok, ".heif"}
      normalized -> {:error, {:unsupported_image_mime_type, normalized}}
    end
  end

  defp image_suffix_for_filename(mime_type) do
    case image_suffix(mime_type) do
      {:ok, suffix} -> suffix
      {:error, _reason} -> ".image"
    end
  end

  defp normalize_encoding(value) when value in [:base64, "base64"], do: "base64"
  defp normalize_encoding(_value), do: "data_url"

  defp normalize_mime_type(mime_type) when is_binary(mime_type) do
    mime_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_mime_type(_mime_type), do: ""

  defp image_mime_type?(mime_type) when is_binary(mime_type),
    do: String.starts_with?(mime_type, "image/")

  defp image_mime_type?(_mime_type), do: false

  defp uuid?(value) when is_binary(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false
end
