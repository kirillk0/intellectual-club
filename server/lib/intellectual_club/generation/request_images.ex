defmodule IntellectualClub.Generation.RequestImages do
  @moduledoc """
  Compacts provider-native request images into stable file markers.

  Preparation validates and pins images before the immutable request is inserted.
  Staged logical files are attached in the same transaction as the new step.
  Hydration reads only step-local bindings and never changes the saved snapshot.
  """

  require Ash.Query

  alias IntellectualClub.Chat.{ContentFiles, ChatMessageStep, ChatMessageStepRequestFile}

  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Generation.RequestImages.{Cache, SourceScope, StagedBindings}
  alias IntellectualClub.Generation.StepRequests
  alias IntellectualClub.Tools.ExecutionContext

  @marker_key "$intellectual_club_file"
  @version 1
  @max_edge_px 2_000
  @identity_variant "identity:v1"
  @thumbnail_variant "thumbnail:max-edge=2000:preserve-format:v1"
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
    %{
      @marker_key => %{
        "version" => @version,
        "reference_key" => source_file_external_id,
        "source_file_external_id" => source_file_external_id,
        "rendition" => %{
          "kind" => "fit",
          "max_edge_px" => @max_edge_px,
          "format" => "preserve"
        },
        "encoding" => normalize_encoding(encoding),
        "mime_type" => normalize_mime_type(mime_type)
      }
    }
  end

  @doc """
  Prepares the final compact request and unbound logical files before step creation.

  The caller supplies an actor-confirmed ContentFiles scope, inserts `request`, and
  attaches `bindings` in one transaction. Discard the staged value after rollback or
  if publication is abandoned. No target message or step needs to exist yet.

  `:source_step_id` requires exact pins for refs inherited from that visible source
  snapshot. Missing, mismatched or corrupt inherited pins never use canonical files.
  Requests without supported markers do not query the database.
  """
  @spec prepare(map(), %ExecutionContext{}, keyword()) ::
          {:ok, %{request: map(), bindings: StagedBindings.t()}} | {:error, term()}
  def prepare(raw_request, scope, opts \\ [])

  def prepare(raw_request, %ExecutionContext{} = scope, opts)
      when is_map(raw_request) and is_list(opts) do
    with {:ok, mapper} <- required_mapper(opts),
         {:ok, descriptors} <- request_descriptors(raw_request, mapper) do
      if map_size(descriptors) == 0 do
        {:ok,
         %{
           request: raw_request,
           bindings: %StagedBindings{items: []},
           image_state: %{request: raw_request, descriptors: %{}, cache: %{}}
         }}
      else
        prepare_images(raw_request, scope, Keyword.put(opts, :mapper, mapper))
      end
    end
  end

  def prepare(_raw_request, _scope, _opts), do: {:error, :invalid_preparation_arguments}

  defp prepare_images(raw_request, scope, opts) do
    StagedBindings.with_scope(
      fn track -> prepare_images_in_scope(raw_request, scope, opts, track) end,
      &cleanup_staged_files/1
    )
  end

  defp prepare_images_in_scope(raw_request, scope, opts, track) do
    chat_scope_ids = ContentFiles.handoff_chat_scope_ids(scope.chat_id, scope.owner_id)

    with {:ok, inherited, bindings} <-
           inherited_snapshot(Keyword.get(opts, :source_step_id), scope, chat_scope_ids, opts) do
      state = %{
        scope: scope,
        chat_scope_ids: chat_scope_ids,
        inherited: inherited,
        bindings: bindings,
        results: %{},
        descriptors: %{},
        staged: [],
        track_staged: track,
        cache: Keyword.get(opts, :cache, %{}),
        used_cache_keys: [],
        error: nil
      }

      {request, state} = opts[:mapper].(raw_request, state, &prepare_block/2)

      case state.error do
        nil ->
          {:ok,
           %{
             request: request,
             bindings: %StagedBindings{items: Enum.reverse(state.staged)},
             image_state: %{
               request: request,
               descriptors: state.descriptors,
               cache: Cache.retain(state.cache, state.used_cache_keys)
             }
           }}

        error ->
          {:error, error_with_cleanup(error, cleanup_staged_files(state.staged))}
      end
    end
  end

  @doc """
  Read-only validation of a saved snapshot, including exact raw equality and pins.

  Payloads are checked once per referenced image, without wire/base64 construction.
  Unreferenced bindings are rejected, never removed. No canonical files are loaded.
  """
  @spec validate_snapshot(map(), integer(), keyword()) :: :ok | {:error, term()}
  def validate_snapshot(raw_request, step_id, opts \\ [])

  def validate_snapshot(raw_request, step_id, opts)
      when is_map(raw_request) and is_integer(step_id) do
    with {:ok, mapper} <- required_mapper(opts),
         {:ok, step} <- load_step(step_id),
         {:ok, saved_request} <-
           StepRequests.request_for_step(step.id, actor: %{id: step.owner_id}),
         :ok <- validate_snapshot_equality(raw_request, saved_request),
         {:ok, bindings} <- bindings_for_step(step_id) do
      validate_snapshot_bindings(
        raw_request,
        bindings,
        mapper
      )
    end
  end

  def validate_snapshot(_raw_request, _step_id, _opts), do: {:error, :invalid_snapshot_arguments}

  @doc """
  Resolves markers using the provider's mapper and this step's bindings. A cache
  hit reuses verified bytes; it never substitutes for resolving a binding.
  """
  def hydrate(raw_request, step_id, opts \\ []) do
    case hydrate_with_cache(raw_request, step_id, opts) do
      {:ok, wire_request, updates} ->
        if on_cache = Keyword.get(opts, :on_cache), do: on_cache.(updates)
        {:ok, wire_request}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Returns private cache updates directly for same-task transport fallback."
  def hydrate_with_cache(raw_request, step_id, opts \\ [])

  def hydrate_with_cache(raw_request, step_id, opts) when is_map(raw_request) and is_list(opts) do
    with {:ok, mapper} <- required_mapper(opts),
         {:ok, descriptors} <- request_descriptors(raw_request, mapper) do
      if map_size(descriptors) == 0 do
        {:ok, raw_request, %{}}
      else
        with {:ok, bindings} <- hydration_bindings(step_id) do
          state = %{
            bindings: Map.new(bindings, &{to_string(&1.reference_key), &1}),
            hydrated: %{},
            cache: Keyword.get(opts, :cache, %{}),
            used_cache_keys: [],
            error: nil
          }

          {wire_request, state} = mapper.(raw_request, state, &hydrate_block/2)

          case state.error do
            nil ->
              {:ok, wire_request, Map.take(state.cache, state.used_cache_keys)}

            error ->
              {:error, error}
          end
        end
      end
    end
  end

  def hydrate_with_cache(_raw_request, _step_id, _opts),
    do: {:error, :invalid_hydration_arguments}

  defp hydration_bindings(nil), do: {:ok, []}
  defp hydration_bindings(step_id) when is_integer(step_id), do: bindings_for_step(step_id)
  defp hydration_bindings(_step_id), do: {:error, :invalid_step_id}

  @doc false
  def mapper(adapter) when is_atom(adapter) and not is_nil(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :map_request_images, 3),
      do: &adapter.map_request_images/3,
      else: &passthrough/3
  end

  def mapper(_adapter), do: &passthrough/3

  @doc """
  Inspects historical requests whose provider configuration may no longer exist.
  Each registered provider owns recognition of its native image paths. This is
  used for read-only copy validation, never for the generation preparation path.
  """
  def inspect_stored_images(request, acc, inspect_reference) do
    IntellectualClub.Llm.Providers.Common.Registry.all()
    |> Enum.reduce(acc, fn adapter, acc ->
      {_request, acc} =
        mapper(adapter).(request, acc, fn reference, acc ->
          {:keep, inspect_reference.(reference, acc)}
        end)

      acc
    end)
  end

  defp required_mapper(opts) do
    case Keyword.get(opts, :mapper) do
      mapper when is_function(mapper, 3) -> {:ok, mapper}
      _ -> {:error, :image_mapper_required}
    end
  end

  defp passthrough(request, acc, _mapper), do: {request, acc}

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

  defp inherited_snapshot(nil, _scope, _chat_scope_ids, _opts), do: {:ok, %{}, %{}}

  defp inherited_snapshot(source_step_id, scope, chat_scope_ids, opts)
       when is_integer(source_step_id) do
    with {:ok, step} <- load_step(source_step_id),
         :ok <- SourceScope.validate(step, scope, chat_scope_ids),
         {:ok, descriptors} <- inherited_descriptors(step, scope, opts),
         {:ok, bindings} <- bindings_for_step(source_step_id) do
      {:ok, descriptors, Map.new(bindings, &{to_string(&1.reference_key), &1})}
    end
  end

  defp inherited_snapshot(_source_step_id, _scope, _chat_scope_ids, _opts),
    do: {:error, :invalid_source_step_id}

  defp inherited_descriptors(step, scope, opts) do
    mapper = Keyword.get(opts, :source_mapper, opts[:mapper])
    # The normal transition has already bound this logical request to its saved
    # predecessor. Cold/direct callers reconstruct through the authorized reader.
    case Keyword.get(opts, :source_request) do
      %{} = request ->
        case Keyword.get(opts, :source_image_state) do
          %{step_id: id, request: cached, descriptors: descriptors}
          when id == step.id and cached === request ->
            {:ok, descriptors}

          _ ->
            request_descriptors(request, mapper, true)
        end

      _ ->
        with {:ok, request} <-
               StepRequests.request_for_step(step.id, actor: %{id: scope.owner_id}),
             do: request_descriptors(request, mapper, true)
    end
  end

  defp prepare_block(_reference, %{error: error} = state) when not is_nil(error),
    do: {:keep, state}

  defp prepare_block(reference, state) do
    with {:ok, descriptor} <- validate_reference(reference),
         :ok <- validate_inherited_descriptor(reference, descriptor, state),
         {:ok, result, state} <- prepare_descriptor(descriptor, state) do
      state = %{state | results: Map.put(state.results, descriptor.reference_key, result)}

      case result do
        %{status: :ok, mime_type: mime_type, image: image} ->
          {_wire, state} = cache_image(image, descriptor, state)
          descriptor = %{descriptor | mime_type: mime_type}

          state = %{
            state
            | descriptors: Map.put(state.descriptors, descriptor.reference_key, descriptor)
          }

          {{:marker, put_marker_mime(reference.marker, mime_type), mime_type}, state}

        %{status: :fallback, text: text} ->
          {{:omit, text}, state}
      end
    else
      {:error, reason} -> {:keep, %{state | error: reason}}
    end
  end

  defp validate_inherited_descriptor(reference, descriptor, state) do
    case Map.get(state.inherited, descriptor.reference_key) do
      nil ->
        :ok

      source ->
        with :ok <- validate_descriptor_match(source, descriptor),
             do: validate_reference_mime(reference, descriptor)
    end
  end

  defp validate_descriptor_match(source, descriptor) do
    cond do
      source.source_file_external_id != descriptor.source_file_external_id ->
        {:error, {:request_image_binding_source_mismatch, descriptor.reference_key}}

      source.mime_type != descriptor.mime_type ->
        {:error, {:request_image_binding_mime_mismatch, descriptor.reference_key}}

      true ->
        :ok
    end
  end

  defp prepare_descriptor(descriptor, state) do
    case Map.fetch(state.results, descriptor.reference_key) do
      {:ok, %{image: image} = result} ->
        key = Cache.key(image.file.sha256, image.mime_type, descriptor.format_key)

        if Map.has_key?(image, :payload) or Map.has_key?(state.cache, key) do
          {:ok, result, state}
        else
          with {:ok, loaded} <- load_valid_image(image.file.id),
               do: {:ok, %{result | image: loaded}, state}
        end

      {:ok, result} ->
        {:ok, result, state}

      :error ->
        if Map.has_key?(state.inherited, descriptor.reference_key) do
          with {:ok, image} <- bound_image(descriptor, state.bindings, state.cache) do
            binding = Map.fetch!(state.bindings, descriptor.reference_key)
            duplicate_and_stage(image, binding.variant_key, descriptor, state)
          end
        else
          prepare_new_image(descriptor, state)
        end
    end
  end

  defp prepare_new_image(descriptor, state) do
    case reusable_binding(descriptor, state) do
      {:ok, binding, image} ->
        duplicate_and_stage(image, binding.variant_key, descriptor, state)

      :not_found ->
        prepare_canonical(descriptor, state)

      {:error, reason} ->
        {:error, {:find_reusable_request_file_failed, reason}}
    end
  end

  defp prepare_canonical(descriptor, state) do
    case ContentFiles.load_payload_for_execution(descriptor.source_file_external_id, state.scope) do
      {:ok, {_content, file, payload}} ->
        prepare_canonical_payload(file, payload, descriptor, state)

      {:error, reason} when reason in [:not_found, :file_not_found, :payload_not_found] ->
        {:ok, %{status: :fallback, text: @invalid_image_fallback}, state}

      {:error, reason} ->
        {:error, {:load_canonical_request_image_failed, reason}}
    end
  end

  defp prepare_canonical_payload(file, payload, descriptor, state) do
    case validate_image_payload(file, payload) do
      {:ok, image} when max(image.width, image.height) <= @max_edge_px ->
        duplicate_and_stage(image, @identity_variant, descriptor, state)

      {:ok, image} ->
        case resize_image_payload(image.payload, image.mime_type) do
          {:ok, resized_payload, resized_mime_type} ->
            filename = rendition_filename(file, descriptor.reference_key, resized_mime_type)

            case Files.create_from_binary(filename, resized_mime_type, resized_payload) do
              {:ok, resized_file} ->
                stage_rendition(resized_file, resized_mime_type, descriptor, state)

              {:error, reason} ->
                {:error, {:create_thumbnail_file_failed, reason}}
            end

          {:error, _reason} ->
            {:ok, %{status: :fallback, text: @resize_fallback}, state}
        end

      {:error, _reason} ->
        {:ok, %{status: :fallback, text: @invalid_image_fallback}, state}
    end
  end

  defp stage_rendition(file, mime_type, descriptor, state) do
    # A content-addressed rendition may already exist on disk. Validate the stored
    # bytes too; creating a logical row must not accidentally reuse a corrupt blob.
    with {:ok, image} <- load_valid_image(file.id),
         true <- image.mime_type == mime_type and max(image.width, image.height) <= @max_edge_px do
      stage_file(file, mime_type, @thumbnail_variant, descriptor, state, image)
    else
      failure ->
        error = {:created_request_image_invalid, failure}
        {:error, error_with_cleanup(error, delete_unbound_file(file.id))}
    end
  end

  defp duplicate_and_stage(image, variant_key, descriptor, state) do
    # Correct metadata only on the new logical file, never on the canonical file or
    # an existing pin. Payload deduplication keeps the same bytes and ownership.
    duplicate =
      if image.file.mime_type == image.mime_type do
        Files.duplicate_file(image.file.id)
      else
        Files.create_from_binary(image.file.filename, image.mime_type, image.payload)
      end

    case duplicate do
      {:ok, file} -> stage_file(file, image.mime_type, variant_key, descriptor, state, image)
      {:error, reason} -> {:error, {:duplicate_request_file_failed, reason}}
    end
  end

  defp stage_file(file, mime_type, variant_key, descriptor, state, image) do
    item = %{
      file_id: file.id,
      reference_key: descriptor.reference_key,
      source_file_external_id: descriptor.source_file_external_id,
      variant_key: variant_key
    }

    state.track_staged.(item)

    {:ok, %{status: :ok, mime_type: mime_type, image: Map.put(image, :file, file)},
     %{state | staged: [item | state.staged]}}
  end

  defp request_descriptors(raw_request, mapper, strict? \\ false) do
    {_request, result} =
      mapper.(raw_request, {:ok, %{}}, fn reference, acc ->
        collect_descriptor(reference, acc, strict?)
      end)

    result
  end

  defp collect_descriptor(_reference, {:error, _reason} = error, _strict?), do: {:keep, error}

  defp collect_descriptor(reference, {:ok, descriptors}, strict?) do
    result =
      with {:ok, descriptor} <- validate_reference(reference),
           :ok <- validate_repeated_descriptor(descriptors, descriptor),
           :ok <- if(strict?, do: validate_reference_mime(reference, descriptor), else: :ok) do
        {:ok, Map.put(descriptors, descriptor.reference_key, descriptor)}
      end

    {:keep, result}
  end

  defp validate_snapshot_equality(raw_request, raw_request), do: :ok
  defp validate_snapshot_equality(_raw_request, _saved), do: {:error, :request_snapshot_mismatch}

  defp validate_snapshot_bindings(raw_request, bindings, mapper) do
    state = %{
      bindings: Map.new(bindings, &{to_string(&1.reference_key), &1}),
      hydrated: %{},
      cache: %{},
      used_cache_keys: [],
      error: nil
    }

    {_request, state} = mapper.(raw_request, state, &validate_snapshot_block/2)

    case state.error do
      nil ->
        case Enum.find(bindings, &(not Map.has_key?(state.hydrated, to_string(&1.reference_key)))) do
          nil ->
            :ok

          binding ->
            {:error, {:unreferenced_request_image_binding, to_string(binding.reference_key)}}
        end

      error ->
        {:error, error}
    end
  end

  defp validate_snapshot_block(_reference, %{error: error} = state) when not is_nil(error),
    do: {:keep, state}

  defp validate_snapshot_block(reference, state) do
    with {:ok, descriptor} <- validate_reference(reference),
         :ok <- validate_reference_mime(reference, descriptor),
         {:ok, image, state} <- hydrated_image(descriptor, state) do
      checked = Map.put(state.hydrated, descriptor.reference_key, Map.take(image, [:mime_type]))
      {:keep, %{state | hydrated: checked}}
    else
      {:error, reason} -> {:keep, %{state | error: reason}}
    end
  end

  defp hydrate_block(_reference, %{error: error} = state) when not is_nil(error),
    do: {:keep, state}

  defp hydrate_block(reference, state) do
    with {:ok, descriptor} <- validate_reference(reference),
         :ok <- validate_reference_mime(reference, descriptor),
         {:ok, image, state} <- hydrated_image(descriptor, state) do
      {cached, state} = cache_image(image, descriptor, state)
      {{:wire, cached.wire, cached.mime_type}, state}
    else
      {:error, reason} -> {:keep, %{state | error: reason}}
    end
  end

  defp cache_image(image, descriptor, state) do
    {cached, cache} = Cache.put(state.cache, image, descriptor)
    key = Cache.key(image.file.sha256, image.mime_type, descriptor.format_key)
    {cached, %{state | cache: cache, used_cache_keys: [key | state.used_cache_keys]}}
  end

  defp hydrated_image(descriptor, state) do
    case Map.fetch(state.hydrated, descriptor.reference_key) do
      {:ok, image} ->
        with :ok <-
               validate_binding_descriptor(
                 Map.fetch!(state.bindings, descriptor.reference_key),
                 descriptor
               ),
             :ok <- validate_image_mime(image, descriptor) do
          # Different occurrences can request different wire representations.
          if Map.has_key?(image, :payload) or not Map.has_key?(image, :wire) or
               Map.has_key?(
                 state.cache,
                 Cache.key(image.file.sha256, image.mime_type, descriptor.format_key)
               ) do
            {:ok, image, state}
          else
            with {:ok, image} <- bound_image(descriptor, state.bindings, state.cache),
                 do:
                   {:ok, image,
                    %{state | hydrated: Map.put(state.hydrated, descriptor.reference_key, image)}}
          end
        end

      :error ->
        with {:ok, image} <- bound_image(descriptor, state.bindings, state.cache),
             do:
               {:ok, image,
                %{state | hydrated: Map.put(state.hydrated, descriptor.reference_key, image)}}
    end
  end

  defp bound_image(descriptor, bindings, cache) do
    with %ChatMessageStepRequestFile{} = binding <- Map.get(bindings, descriptor.reference_key),
         :ok <- validate_binding_descriptor(binding, descriptor),
         {:ok, image} <- cached_or_loaded_image(binding, descriptor, cache),
         true <- max(image.width, image.height) <= @max_edge_px,
         :ok <- validate_image_mime(image, descriptor) do
      {:ok, image}
    else
      nil -> {:error, {:request_image_binding_not_found, descriptor.reference_key}}
      false -> {:error, {:request_image_binding_oversized, descriptor.reference_key}}
      {:error, _reason} = error -> error
    end
  end

  defp cached_or_loaded_image(binding, descriptor, cache) do
    case Cache.fetch(cache, binding.file, descriptor) do
      {:ok, image} -> {:ok, image}
      :error -> load_valid_image(binding.file_id)
    end
  end

  defp validate_image_mime(image, descriptor) do
    if image.mime_type == descriptor.mime_type,
      do: :ok,
      else: {:error, {:request_image_binding_mime_mismatch, descriptor.reference_key}}
  end

  defp validate_reference_mime(reference, descriptor) do
    if reference.mime_type == descriptor.mime_type,
      do: :ok,
      else: {:error, {:request_image_block_mime_mismatch, descriptor.reference_key}}
  end

  defp validate_reference(reference) do
    with {:ok, descriptor} <- validate_marker(reference.marker, reference.encoding) do
      {:ok, Map.merge(descriptor, Map.take(reference, [:format_key, :format]))}
    end
  end

  defp validate_marker(marker, expected_encoding) when is_map(marker) do
    reference_key = Map.get(marker, "reference_key")
    source_file_external_id = Map.get(marker, "source_file_external_id")
    rendition = Map.get(marker, "rendition")
    encoding = Map.get(marker, "encoding")
    mime_type = normalize_mime_type(Map.get(marker, "mime_type"))

    cond do
      Map.get(marker, "version") != @version ->
        {:error, {:unsupported_request_image_marker_version, Map.get(marker, "version")}}

      not uuid?(reference_key) ->
        {:error, :invalid_request_image_reference_key}

      not uuid?(source_file_external_id) ->
        {:error, :invalid_request_image_source_file_external_id}

      rendition != %{
        "kind" => "fit",
        "max_edge_px" => @max_edge_px,
        "format" => "preserve"
      } ->
        {:error, :unsupported_request_image_rendition}

      encoding != expected_encoding ->
        {:error, {:invalid_request_image_encoding, expected_encoding, encoding}}

      not image_mime_type?(mime_type) ->
        {:error, :invalid_request_image_mime_type}

      true ->
        {:ok,
         %{
           reference_key: reference_key,
           source_file_external_id: source_file_external_id,
           mime_type: mime_type
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

      binding.variant_key not in [@identity_variant, @thumbnail_variant] ->
        {:error, {:unsupported_request_image_binding_variant, binding.variant_key}}

      true ->
        :ok
    end
  end

  defp load_valid_image(file_id) do
    with {:ok, {file, payload}} <- Files.load_payload(file_id) do
      :telemetry.execute(
        [:intellectual_club, :generation, :request_image_cache],
        %{loaded_bytes: byte_size(payload)},
        %{}
      )

      validate_image_payload(file, payload)
    end
  end

  defp validate_image_payload(file, payload) do
    with true <- is_binary(payload),
         :ok <- validate_payload_integrity(file, payload),
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
  rescue
    _error -> {:error, :invalid_image_payload}
  end

  defp validate_payload_integrity(file, payload) do
    if byte_size(payload) == file.size_bytes and
         Base.encode16(:crypto.hash(:sha256, payload), case: :lower) == file.sha256 do
      :ok
    else
      {:error, :request_image_payload_integrity_mismatch}
    end
  end

  defp resize_image_payload(payload, mime_type) do
    try do
      with {:ok, resized_payload, _backend_mime_type} <-
             IntellectualClub.ImageProcessor.resize_down(payload, mime_type, @max_edge_px),
           {resized_mime_type, width, height, _variant}
           when is_binary(resized_mime_type) and is_integer(width) and is_integer(height) and
                  width > 0 and height > 0 <- ExImageInfo.info(resized_payload),
           true <- image_mime_type?(resized_mime_type),
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
    |> Ash.Query.select([:id, :owner_id, :chat_message_id])
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

  defp reusable_binding(_descriptor, %{chat_scope_ids: []}), do: :not_found
  defp reusable_binding(_descriptor, %{scope: %{owner_id: nil}}), do: :not_found

  defp reusable_binding(descriptor, state) do
    ChatMessageStepRequestFile
    |> Ash.Query.filter(
      reference_key == ^descriptor.reference_key and
        source_file_external_id == ^descriptor.source_file_external_id and
        chat_message_step.owner_id == ^state.scope.owner_id and
        chat_message_step.chat_message.chat_id in ^state.chat_scope_ids
    )
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(:file)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %ChatMessageStepRequestFile{} = binding} ->
        with :ok <- validate_binding_descriptor(binding, descriptor),
             {:ok, image} <- cached_or_loaded_image(binding, descriptor, state.cache),
             true <- max(image.width, image.height) <= @max_edge_px do
          {:ok, binding, image}
        else
          false ->
            :not_found

          {:error, reason}
          when reason in [
                 :payload_not_found,
                 :invalid_image_payload,
                 :not_an_image,
                 :request_image_payload_integrity_mismatch
               ] ->
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

      {:error, reason} when not cleanup_on_error? ->
        {:error, {:attach_staged_binding_failed, item.reference_key, reason}}

      {:error, reason} ->
        case binding_for_reference(target_step_id, item.reference_key) do
          {:ok, %ChatMessageStepRequestFile{} = winner} ->
            if staged_binding_matches?(winner, item) do
              case cleanup_staged_files([item]) do
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

          {:ok, nil} ->
            attach_staged_failure(
              {:attach_staged_binding_failed, item.reference_key, reason},
              attached_binding_ids,
              [item | rest]
            )

          {:error, lookup_reason} ->
            attach_staged_failure(
              {:attach_staged_binding_lookup_failed, item.reference_key, reason, lookup_reason},
              attached_binding_ids,
              [item | rest]
            )
        end
    end
  end

  defp staged_binding_matches?(binding, item) do
    with true <-
           to_string(binding.source_file_external_id) == to_string(item.source_file_external_id),
         true <- binding.variant_key == item.variant_key,
         %StoredFile{} = bound_file <- binding.file,
         {:ok, %StoredFile{} = staged_file} <-
           Ash.get(StoredFile, item.file_id, authorize?: false) do
      bound_file.sha256 == staged_file.sha256 and bound_file.size_bytes == staged_file.size_bytes
    else
      _other -> false
    end
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

  defp put_marker_mime(marker, mime_type), do: Map.put(marker, "mime_type", mime_type)

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
