defmodule IntellectualClub.Generation.RequestImages do
  @moduledoc """
  Compacts provider-native request images into stable file markers.

  Preparation validates and pins images before the immutable request is inserted.
  Staged logical files are attached in the same transaction as the new step.
  Hydration reads only step-local bindings and never changes the saved snapshot.

  Images are never decoded or resized. Validity comes from content verdicts
  (`IntellectualClub.Files.ImageVerdicts`) checked after every cold payload load
  verifies size and SHA-256. Images that are invalid, over the request limits or
  rejected by the current LLM configuration (`:llm_configuration_id`, see
  `IntellectualClub.Files.ImageProviderVerdicts`) are replaced by provider-native
  text naming their `file_id`; inherited pins are only checked against the edge
  limit.
  """

  require Ash.Query

  alias IntellectualClub.Chat.{ContentFiles, ChatMessageStep, ChatMessageStepRequestFile}

  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.{ImageProviderVerdicts, ImageVerdicts}
  alias IntellectualClub.Generation.RequestImages.{Cache, Omissions, SourceScope, StagedBindings}
  alias IntellectualClub.Generation.StepRequests
  alias IntellectualClub.ImageProcessor
  alias IntellectualClub.Tools.ExecutionContext

  @marker_key "$intellectual_club_file"
  @version 1
  @max_edge_px 2_000
  @identity_variant "identity:v1"
  # Pins created by earlier releases. They are still read, but no longer created:
  # downscaled renditions, and exact bytes captured by the raw request backfill
  # (which may exceed the request limits and then become text).
  @thumbnail_variant "thumbnail:max-edge=2000:preserve-format:v1"
  @legacy_exact_variant "legacy_exact:v1"
  @fit_rendition %{"kind" => "fit", "max_edge_px" => @max_edge_px, "format" => "preserve"}
  # Rendition of markers written by the raw request backfill.
  @legacy_exact_rendition %{"kind" => "legacy_exact", "format" => "preserve"}

  @type encoding :: :data_url | :base64 | String.t()

  @typedoc """
  An image a hydrated request sends natively: its pin, and whether the current
  LLM configuration has accepted that content before.
  """
  @type sent_image :: %{
          sha256: String.t(),
          file_id: integer(),
          source_file_external_id: String.t(),
          accepted?: boolean()
        }

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
        "rendition" => @fit_rendition,
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
  Requests without supported markers do not query the database. Images rejected
  by `:llm_configuration_id` become text; their facts are loaded with one query
  after all images are resolved.
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
           image_state: %{request: raw_request, descriptors: %{}, cache: %{}, images: %{}}
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
    chat_scope_ids = List.wrap(scope.chat_id)

    with {:ok, inherited, bindings} <-
           inherited_snapshot(Keyword.get(opts, :source_step_id), scope, chat_scope_ids, opts),
         {:ok, verdicts} <- preload_verdicts(Map.values(bindings)) do
      state = %{
        scope: scope,
        chat_scope_ids: chat_scope_ids,
        inherited: inherited,
        bindings: bindings,
        verdicts: verdicts,
        llm_configuration_id: Keyword.get(opts, :llm_configuration_id),
        # Checked once for all staged images, after traversal.
        provider_facts: %{},
        results: %{},
        descriptors: %{},
        images: %{},
        staged: [],
        track_staged: track,
        cache: Keyword.get(opts, :cache, %{}),
        used_cache_keys: [],
        error: nil
      }

      {request, state} = opts[:mapper].(raw_request, state, &prepare_block/2)

      result =
        case state.error do
          nil -> omit_provider_rejected(request, state, opts[:mapper])
          error -> {:error, error}
        end

      case result do
        {:ok, request, state} ->
          {:ok,
           %{
             request: request,
             bindings: %StagedBindings{items: Enum.reverse(state.staged)},
             image_state: %{
               request: request,
               descriptors: state.descriptors,
               cache: Cache.retain(state.cache, state.used_cache_keys),
               images: state.images
             }
           }}

        # Includes files a failed replacement of rejected images did not discard.
        {:error, error} ->
          {:error, error_with_cleanup(error, cleanup_staged_files(state.staged))}
      end
    end
  end

  # New images are only identified while traversing, so the facts of the current
  # configuration are loaded once for all staged images afterwards. Rejected ones
  # are then replaced with text and their staged files discarded.
  defp omit_provider_rejected(
         request,
         %{llm_configuration_id: id, images: images} = state,
         mapper
       )
       when is_integer(id) and map_size(images) > 0 do
    sha256s = images |> Map.values() |> Enum.map(& &1.sha256)

    case ImageProviderVerdicts.load(sha256s, id) do
      {:ok, facts} ->
        texts =
          for {reference_key, %{sha256: sha256}} <- images,
              Map.get(facts, sha256) == :rejected,
              into: %{},
              do: {reference_key, rejected_text(reference_key, state)}

        if texts == %{},
          do: {:ok, request, state},
          else: replace_rejected(request, state, mapper, texts)

      {:error, reason} ->
        {:error, {:load_image_provider_verdicts_failed, reason}}
    end
  end

  defp omit_provider_rejected(request, state, _mapper), do: {:ok, request, state}

  defp rejected_text(reference_key, state) do
    case {Map.get(state.results, reference_key), Map.get(state.descriptors, reference_key)} do
      {%{image: image}, %{source_file_external_id: source}} ->
        Omissions.text(:provider_rejected, image.file, source, image)

      # A later occurrence already became text after staging; keep it generic.
      _other ->
        Omissions.unavailable()
    end
  end

  defp replace_rejected(request, state, mapper, texts) do
    {request, nil} =
      mapper.(request, nil, fn reference, nil ->
        case validate_reference(reference) do
          {:ok, %{reference_key: key}} when is_map_key(texts, key) ->
            {{:omit, Map.fetch!(texts, key)}, nil}

          _other ->
            {:keep, nil}
        end
      end)

    keys = Map.keys(texts)
    rejected = state.images |> Map.take(keys) |> Map.values() |> MapSet.new(& &1.sha256)
    {discarded, staged} = Enum.split_with(state.staged, &is_map_key(texts, &1.reference_key))

    used_cache_keys =
      Enum.reject(state.used_cache_keys, fn {sha256, _mime, _format} ->
        MapSet.member?(rejected, sha256)
      end)

    case cleanup_staged_files(discarded) do
      :ok ->
        {:ok, request,
         %{
           state
           | staged: staged,
             descriptors: Map.drop(state.descriptors, keys),
             images: Map.drop(state.images, keys),
             used_cache_keys: used_cache_keys
         }}

      {:error, reason} ->
        {:error, {:discard_rejected_request_images_failed, reason}}
    end
  end

  @doc """
  Read-only validation of a saved snapshot, including exact raw equality and pins.

  Payloads are checked once per referenced image, without wire/base64 construction.
  Pins whose content verdict is invalid are accepted: hydration replaces them with
  text, as it does for images rejected by its configuration. Unreferenced bindings
  are rejected, never removed. No canonical files are loaded.
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
  Pins whose content verdict is invalid, or which `:llm_configuration_id` has
  rejected, become text; a warm cache does not bypass either check.

  After a successful hydration `:on_cache` receives the cache entries the wire
  request uses and `:on_sent` the `t:sent_image/0` list of images it sends
  natively (possibly empty), before the request is transmitted.
  """
  def hydrate(raw_request, step_id, opts \\ []) do
    case hydrate_with_cache(raw_request, step_id, opts) do
      {:ok, wire_request, updates, sent} ->
        if on_cache = Keyword.get(opts, :on_cache), do: on_cache.(updates)
        if on_sent = Keyword.get(opts, :on_sent), do: on_sent.(sent)
        {:ok, wire_request}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Returns `{:ok, wire_request, cache_updates, sent_images}` directly instead of
  calling the callbacks of `hydrate/3`.
  """
  def hydrate_with_cache(raw_request, step_id, opts \\ [])

  def hydrate_with_cache(raw_request, step_id, opts) when is_map(raw_request) and is_list(opts) do
    with {:ok, mapper} <- required_mapper(opts),
         {:ok, descriptors} <- request_descriptors(raw_request, mapper) do
      if map_size(descriptors) == 0 do
        {:ok, raw_request, %{}, []}
      else
        configuration_id = Keyword.get(opts, :llm_configuration_id)

        with {:ok, bindings} <- hydration_bindings(step_id),
             {:ok, verdicts} <- preload_verdicts(bindings),
             {:ok, facts} <- preload_provider_facts(bindings, configuration_id) do
          state = %{
            bindings: Map.new(bindings, &{to_string(&1.reference_key), &1}),
            verdicts: verdicts,
            provider_facts: facts,
            hydrated: %{},
            sent: %{},
            cache: Keyword.get(opts, :cache, %{}),
            used_cache_keys: [],
            error: nil
          }

          {wire_request, state} = mapper.(raw_request, state, &hydrate_block/2)

          case state.error do
            nil ->
              {:ok, wire_request, Map.take(state.cache, state.used_cache_keys),
               state.sent |> Map.values() |> Enum.sort_by(& &1.sha256)}

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
          # Another occurrence needs a different wire format of the staged file.
          case load_image(image.file.id, descriptor, state) do
            {:ok, loaded, state} -> {:ok, %{result | image: loaded}, state}
            {:omit, text, state} -> {:ok, fallback(text), state}
            {:error, _reason} = error -> error
          end
        end

      {:ok, result} ->
        {:ok, result, state}

      :error ->
        if Map.has_key?(state.inherited, descriptor.reference_key) do
          prepare_inherited(descriptor, state)
        else
          prepare_new_image(descriptor, state)
        end
    end
  end

  # Inherited pins keep their bytes and are not checked against the byte limit
  # again; an invalid verdict or the edge limit replaces them, and so does a
  # rejection by the current configuration after traversal.
  defp prepare_inherited(descriptor, state) do
    case bound_image(descriptor, state) do
      {:ok, image, state} ->
        binding = Map.fetch!(state.bindings, descriptor.reference_key)
        duplicate_and_stage(image, binding.variant_key, descriptor, state, :inherited)

      {:omit, text, state} ->
        {:ok, fallback(text), state}

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_new_image(descriptor, state) do
    case reusable_binding(descriptor, state) do
      {:ok, binding, image, state} ->
        duplicate_and_stage(image, binding.variant_key, descriptor, state, :reused)

      {:not_found, state} ->
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
        {:ok, fallback(Omissions.unavailable()), state}

      {:error, reason} ->
        {:error, {:load_canonical_request_image_failed, reason}}
    end
  end

  # New images are pinned unchanged or replaced by text; they are never resized.
  # Header limits are checked first, so oversized images are not validated.
  defp prepare_canonical_payload(file, payload, descriptor, state) do
    source = descriptor.source_file_external_id

    with :ok <- validate_payload_integrity(file, payload),
         :ok <- check_header_limits(file, payload) do
      case verified_image(file, payload, descriptor, state) do
        {:ok, image, state} ->
          case ImageProcessor.check_limits(image, file.size_bytes) do
            :ok ->
              duplicate_and_stage(image, @identity_variant, descriptor, state, :new)

            {:error, _limit} ->
              {:ok, fallback(Omissions.text(:over_limit, file, source, image)), state}
          end

        {:omit, text, state} ->
          {:ok, fallback(text), state}

        {:error, _reason} = error ->
          error
      end
    else
      {:over_limit, header} ->
        {:ok, fallback(Omissions.text(:over_limit, file, source, header)), state}

      {:error, :request_image_payload_integrity_mismatch} ->
        {:ok, fallback(Omissions.text(:invalid, file, source, nil)), state}
    end
  end

  defp check_header_limits(file, payload) do
    with {:ok, header} <- ImageProcessor.header(payload),
         {:error, _limit} <- ImageProcessor.check_limits(header, file.size_bytes) do
      {:over_limit, header}
    else
      # Within the limits, or not even a readable header: the verdict decides.
      _other -> :ok
    end
  end

  defp fallback(text), do: %{status: :fallback, text: text}

  defp duplicate_and_stage(image, variant_key, descriptor, state, origin) do
    # Correct metadata only on the new logical file, never on the canonical file or
    # an existing pin. Payload deduplication keeps the same bytes and ownership.
    duplicate =
      if image.file.mime_type == image.mime_type do
        Files.duplicate_file(image.file.id)
      else
        Files.create_from_binary(image.file.filename, image.mime_type, image.payload)
      end

    case duplicate do
      {:ok, file} ->
        stage_file(file, image.mime_type, variant_key, descriptor, state, image, origin)

      {:error, reason} ->
        {:error, {:duplicate_request_file_failed, reason}}
    end
  end

  # `origin` is :inherited (exact pin of the source step), :reused (pin of another
  # step in scope) or :new (canonical file); see the `images` field of image_state.
  # It records provenance only and is not used to blame images.
  defp stage_file(file, mime_type, variant_key, descriptor, state, image, origin) do
    item = %{
      file_id: file.id,
      reference_key: descriptor.reference_key,
      source_file_external_id: descriptor.source_file_external_id,
      variant_key: variant_key
    }

    state.track_staged.(item)
    staged_image = %{sha256: file.sha256, origin: origin}

    {:ok, %{status: :ok, mime_type: mime_type, image: Map.put(image, :file, file)},
     %{
       state
       | staged: [item | state.staged],
         images: Map.put(state.images, descriptor.reference_key, staged_image)
     }}
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
    with {:ok, verdicts} <- preload_verdicts(bindings) do
      validate_snapshot_bindings(raw_request, bindings, mapper, verdicts)
    end
  end

  defp validate_snapshot_bindings(raw_request, bindings, mapper, verdicts) do
    state = %{
      bindings: Map.new(bindings, &{to_string(&1.reference_key), &1}),
      verdicts: verdicts,
      provider_facts: %{},
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
         :ok <- validate_reference_mime(reference, descriptor) do
      case hydrated_image(descriptor, state) do
        {:ok, image, state} ->
          # Keep only what repeated occurrences compare, not the payload.
          checked =
            Map.put(state.hydrated, descriptor.reference_key, Map.take(image, [:mime_type]))

          {:keep, %{state | hydrated: checked}}

        {:omit, _text, state} ->
          {:keep, state}

        {:error, reason} ->
          {:keep, %{state | error: reason}}
      end
    else
      {:error, reason} -> {:keep, %{state | error: reason}}
    end
  end

  defp hydrate_block(_reference, %{error: error} = state) when not is_nil(error),
    do: {:keep, state}

  defp hydrate_block(reference, state) do
    with {:ok, descriptor} <- validate_reference(reference),
         :ok <- validate_reference_mime(reference, descriptor) do
      case hydrated_image(descriptor, state) do
        {:ok, image, state} ->
          {cached, state} = cache_image(image, descriptor, state)
          {{:wire, cached.wire, cached.mime_type}, put_sent(state, image, descriptor)}

        {:omit, text, state} ->
          {{:omit, text}, state}

        {:error, reason} ->
          {:keep, %{state | error: reason}}
      end
    else
      {:error, reason} -> {:keep, %{state | error: reason}}
    end
  end

  defp put_sent(state, %{file: file}, descriptor) do
    sent = %{
      sha256: file.sha256,
      file_id: file.id,
      source_file_external_id: descriptor.source_file_external_id,
      accepted?: Map.get(state.provider_facts, file.sha256) == :accepted
    }

    %{state | sent: Map.put_new(state.sent, file.sha256, sent)}
  end

  defp cache_image(image, descriptor, state) do
    {cached, cache} = Cache.put(state.cache, image, descriptor)
    key = Cache.key(image.file.sha256, image.mime_type, descriptor.format_key)
    {cached, %{state | cache: cache, used_cache_keys: [key | state.used_cache_keys]}}
  end

  defp hydrated_image(descriptor, state) do
    reference_key = descriptor.reference_key

    case Map.fetch(state.hydrated, reference_key) do
      {:ok, %{omit: text}} ->
        with :ok <-
               validate_binding_descriptor(Map.fetch!(state.bindings, reference_key), descriptor),
             do: {:omit, text, state}

      {:ok, image} ->
        with :ok <-
               validate_binding_descriptor(Map.fetch!(state.bindings, reference_key), descriptor),
             :ok <- validate_image_mime(image, descriptor) do
          # Different occurrences can request different wire representations.
          if Map.has_key?(image, :payload) or not Map.has_key?(image, :wire) or
               Map.has_key?(
                 state.cache,
                 Cache.key(image.file.sha256, image.mime_type, descriptor.format_key)
               ) do
            {:ok, image, state}
          else
            resolve_hydrated(descriptor, state)
          end
        end

      :error ->
        resolve_hydrated(descriptor, state)
    end
  end

  defp resolve_hydrated(descriptor, state) do
    case bound_image(descriptor, state) do
      {:ok, image, state} ->
        {:ok, image, put_hydrated(state, descriptor, image)}

      {:omit, text, state} ->
        {:omit, text, put_hydrated(state, descriptor, %{omit: text})}

      {:error, _reason} = error ->
        error
    end
  end

  defp put_hydrated(state, descriptor, value),
    do: %{state | hydrated: Map.put(state.hydrated, descriptor.reference_key, value)}

  # The byte limit is not applied again, so that earlier conversations keep their
  # images. Pins above the edge limit (the raw request backfill pinned exact bytes)
  # become text instead of failing the request, as do pins rejected by the current
  # configuration (checked before the cache and the payload).
  defp bound_image(descriptor, state) do
    reference_key = descriptor.reference_key

    with %ChatMessageStepRequestFile{} = binding <- Map.get(state.bindings, reference_key),
         :ok <- validate_binding_descriptor(binding, descriptor) do
      sha256 = binding.file.sha256

      if Map.get(state.provider_facts, sha256) == :rejected do
        source = descriptor.source_file_external_id
        verdict = Map.get(state.verdicts, sha256)
        {:omit, Omissions.text(:provider_rejected, binding.file, source, verdict), state}
      else
        bound_image(binding, descriptor, state)
      end
    else
      nil -> {:error, {:request_image_binding_not_found, reference_key}}
      {:error, _reason} = error -> error
    end
  end

  defp bound_image(binding, descriptor, state) do
    reference_key = descriptor.reference_key

    case binding_image(binding, descriptor, state) do
      {:ok, image, state} ->
        cond do
          image.mime_type != descriptor.mime_type ->
            {:error, {:request_image_binding_mime_mismatch, reference_key}}

          max(image.width, image.height) > @max_edge_px ->
            source = descriptor.source_file_external_id
            {:omit, Omissions.text(:over_limit, binding.file, source, image), state}

          true ->
            {:ok, image, state}
        end

      other ->
        other
    end
  end

  # A cache hit reuses bytes verified earlier by this process; only an invalid
  # verdict recorded since then overrides it.
  defp binding_image(binding, descriptor, state) do
    case Cache.fetch(state.cache, binding.file, descriptor) do
      {:ok, image} ->
        with {:ok, verdict, verdicts} <-
               ImageVerdicts.fetch(binding.file.sha256, state.verdicts) do
          state = %{state | verdicts: verdicts}

          case ImageVerdicts.classify(verdict) do
            :invalid ->
              text =
                Omissions.text(
                  :invalid,
                  binding.file,
                  descriptor.source_file_external_id,
                  verdict
                )

              {:omit, text, state}

            _valid_or_unchecked ->
              {:ok, image, state}
          end
        end

      :error ->
        load_image(binding.file_id, descriptor, state)
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

      rendition not in [@fit_rendition, @legacy_exact_rendition] ->
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

      binding.variant_key not in [@identity_variant, @thumbnail_variant, @legacy_exact_variant] ->
        {:error, {:unsupported_request_image_binding_variant, binding.variant_key}}

      true ->
        :ok
    end
  end

  defp load_image(file_id, descriptor, state) do
    with {:ok, {file, payload}} <- Files.load_payload(file_id) do
      :telemetry.execute(
        [:intellectual_club, :generation, :request_image_cache],
        %{loaded_bytes: byte_size(payload)},
        %{}
      )

      with :ok <- validate_payload_integrity(file, payload),
           do: verified_image(file, payload, descriptor, state)
    end
  end

  # Only for payloads already checked against the file's size and SHA-256.
  defp verified_image(file, payload, descriptor, state) do
    with {:ok, verdict, verdicts} <- ImageVerdicts.ensure(file, payload, state.verdicts) do
      state = %{state | verdicts: verdicts}

      case ImageVerdicts.classify(verdict) do
        :valid ->
          image = %{
            file: file,
            payload: payload,
            mime_type: verdict.mime_type,
            width: verdict.width,
            height: verdict.height
          }

          {:ok, image, state}

        :invalid ->
          text = Omissions.text(:invalid, file, descriptor.source_file_external_id, verdict)
          {:omit, text, state}
      end
    end
  end

  defp preload_verdicts(bindings), do: bindings |> binding_sha256s() |> ImageVerdicts.load()

  defp preload_provider_facts(bindings, configuration_id) do
    case bindings |> binding_sha256s() |> ImageProviderVerdicts.load(configuration_id) do
      {:ok, facts} -> {:ok, facts}
      {:error, reason} -> {:error, {:load_image_provider_verdicts_failed, reason}}
    end
  end

  defp binding_sha256s(bindings) do
    Enum.flat_map(bindings, fn
      %{file: %StoredFile{sha256: sha256}} -> [sha256]
      _binding -> []
    end)
  end

  defp validate_payload_integrity(file, payload) do
    if byte_size(payload) == file.size_bytes and
         Base.encode16(:crypto.hash(:sha256, payload), case: :lower) == file.sha256 do
      :ok
    else
      {:error, :request_image_payload_integrity_mismatch}
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

  defp reusable_binding(_descriptor, %{chat_scope_ids: []} = state), do: {:not_found, state}
  defp reusable_binding(_descriptor, %{scope: %{owner_id: nil}} = state), do: {:not_found, state}

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
        # Reused pins are new to this request, so the request limits apply.
        # Unusable candidates fall back to the canonical file, which decides.
        with :ok <- validate_binding_descriptor(binding, descriptor),
             {:ok, image, state} <- binding_image(binding, descriptor, state),
             :ok <- ImageProcessor.check_limits(image, binding.file.size_bytes) do
          {:ok, binding, image, state}
        else
          {:omit, _text, state} ->
            {:not_found, state}

          {:error, reason}
          when reason in [
                 :payload_not_found,
                 :request_image_payload_integrity_mismatch,
                 :image_dimensions_exceed_limit,
                 :image_bytes_exceed_limit
               ] ->
            {:not_found, state}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, nil} ->
        {:not_found, state}

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
