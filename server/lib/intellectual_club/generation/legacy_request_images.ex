defmodule IntellectualClub.Generation.LegacyRequestImages do
  @moduledoc """
  Converts provider-native legacy image payloads in raw requests into compact file markers.

  Legacy wire bytes are staged as logical files before a short per-step transaction. The
  transaction locks the step, creates all bindings, and replaces the raw request atomically.
  Controlled failures leave the legacy request untouched and compensate staged logical files.
  """

  require Ash.Query

  alias IntellectualClub.Chat.{
    ChatMessageContent,
    ChatMessageStep,
    ChatMessageStepRequestFile,
    ContentFiles
  }

  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Generation.LegacyRequestImages.Walker
  alias IntellectualClub.Generation.RequestImages
  alias IntellectualClub.Repo

  @max_edge_px 2_000
  @identity_variant "identity:v1"
  @thumbnail_variant "thumbnail:max-edge=2000:preserve-format:v1"
  @legacy_exact_variant "legacy_exact:v1"
  @staged_filename_prefix "legacy-raw-request-backfill-"
  @terminal_statuses [:done, :error, :canceled]

  @type migration_status :: :noop | :active | :candidate | :migrated

  @type migration_result :: %{
          required(:status) => migration_status(),
          required(:step_id) => integer(),
          optional(:occurrences) => non_neg_integer(),
          optional(:bindings) => non_neg_integer(),
          optional(:encoded_chars) => non_neg_integer(),
          optional(:decoded_bytes) => non_neg_integer(),
          optional(:legacy_json_bytes) => non_neg_integer(),
          optional(:compact_json_bytes) => non_neg_integer(),
          optional(:identity_bindings) => non_neg_integer(),
          optional(:thumbnail_bindings) => non_neg_integer(),
          optional(:legacy_exact_bindings) => non_neg_integer(),
          optional(:missing_sources) => non_neg_integer(),
          optional(:wire_changed_oversized) => non_neg_integer(),
          optional(:payloads) => list(map()),
          optional(:cleanup_errors) => list(term())
        }

  @doc """
  Analyzes or migrates one step.

  Pass `dry_run?: true` to validate and calculate the compact request without creating files or
  changing the database.
  """
  @spec migrate_step(integer(), keyword()) :: {:ok, migration_result()} | {:error, term()}
  def migrate_step(step_id, opts \\ [])

  def migrate_step(step_id, opts) when is_integer(step_id) and is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run?, true)

    with {:ok, step} <- load_step(step_id) do
      cond do
        step.status not in @terminal_statuses ->
          {:ok, %{status: :active, step_id: step.id}}

        true ->
          migrate_loaded_step(step, dry_run?)
      end
    end
  end

  def migrate_step(_step_id, _opts), do: {:error, :invalid_step_id}

  @doc false
  @spec staged_filename_prefix() :: String.t()
  def staged_filename_prefix, do: @staged_filename_prefix

  @doc false
  @spec cleanup_unbound_staged_files() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_unbound_staged_files do
    StoredFile
    |> Ash.Query.filter(
      string_starts_with(filename, ^@staged_filename_prefix) and
        not exists(chat_message_step_request_file)
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, files} ->
        files
        |> Enum.reduce_while({:ok, 0}, fn file, {:ok, count} ->
          case Files.delete_file_and_maybe_payload(file.id) do
            :ok -> {:cont, {:ok, count + 1}}
            {:error, reason} -> {:halt, {:error, {file.id, reason}}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp migrate_loaded_step(step, dry_run?) do
    case prepare(step) do
      {:ok, %{occurrences: 0}} ->
        {:ok, %{status: :noop, step_id: step.id}}

      {:ok, prepared} when dry_run? ->
        {:ok, result(prepared, :candidate, [])}

      {:ok, prepared} ->
        apply_prepared(step, prepared)

      {:error, reason} ->
        {:error, {:legacy_request_image_prepare_failed, step.id, reason}}
    end
  end

  defp prepare(step) do
    initial_state = %{
      step: step,
      descriptors: %{},
      descriptor_order: [],
      source_cache: %{},
      occurrences: 0,
      encoded_chars: 0,
      decoded_bytes: 0,
      missing_sources: 0,
      wire_changed_oversized: 0,
      error: nil
    }

    {compact_request, state} =
      Walker.compact(step.raw_request, initial_state, &compact_legacy_block/5)

    case state.error do
      nil ->
        descriptors = Enum.map(state.descriptor_order, &Map.fetch!(state.descriptors, &1))

        {:ok,
         %{
           step_id: step.id,
           original_request: step.raw_request,
           compact_request: compact_request,
           descriptors: descriptors,
           occurrences: state.occurrences,
           encoded_chars: state.encoded_chars,
           decoded_bytes: state.decoded_bytes,
           missing_sources: state.missing_sources,
           wire_changed_oversized: state.wire_changed_oversized,
           legacy_json_bytes: encoded_json_size(step.raw_request),
           compact_json_bytes: encoded_json_size(compact_request)
         }}

      error ->
        {:error, error}
    end
  end

  defp compact_legacy_block(_shape, _block, _image, _reference, %{error: error} = state)
       when not is_nil(error),
       do: {:error, error, state}

  defp compact_legacy_block(shape, block, image, reference, state) do
    with {:ok, decoded} <- decode_image(image),
         {:ok, source, state} <- resolve_source(reference, decoded, state),
         {:ok, normalized} <- normalize_payload(decoded, source),
         {:ok, state} <- put_descriptor(normalized, source, image, state) do
      marker = marker(normalized, source.external_id, encoding_for_shape(shape))

      next_state = %{
        state
        | occurrences: state.occurrences + 1,
          encoded_chars: state.encoded_chars + image.encoded_chars,
          decoded_bytes: state.decoded_bytes + byte_size(decoded.payload),
          missing_sources: state.missing_sources + if(source.missing?, do: 1, else: 0),
          wire_changed_oversized:
            state.wire_changed_oversized + if(normalized.wire_changed?, do: 1, else: 0)
      }

      {:ok, put_marker(shape, block, marker, normalized.mime_type), next_state}
    else
      {:error, reason, failed_state} ->
        {:error, reason, %{failed_state | error: reason}}

      {:error, reason} ->
        {:error, reason, %{state | error: reason}}
    end
  end

  defp decode_image(image) do
    with declared_mime_type when is_binary(declared_mime_type) <-
           normalize_mime_type(image.declared_mime_type),
         true <- image_mime_type?(declared_mime_type),
         {:ok, payload} <- Base.decode64(image.encoded, ignore: :whitespace),
         {actual_mime_type, width, height, _variant}
         when is_binary(actual_mime_type) and is_integer(width) and width > 0 and
                is_integer(height) and height > 0 <- ExImageInfo.info(payload),
         actual_mime_type <- normalize_mime_type(actual_mime_type),
         true <- image_mime_type?(actual_mime_type) do
      {:ok,
       %{
         payload: payload,
         sha256: sha256(payload),
         mime_type: actual_mime_type,
         width: width,
         height: height
       }}
    else
      :error -> {:error, :invalid_base64}
      false -> {:error, :invalid_image_mime_type}
      nil -> {:error, :invalid_image_payload}
      other -> {:error, {:invalid_legacy_image, other}}
    end
  end

  defp resolve_source(%{kind: kind, external_id: external_id} = reference, decoded, state)
       when kind in [:file, :content] do
    cache_key = {kind, external_id}

    case Map.fetch(state.source_cache, cache_key) do
      {:ok, source} ->
        {:ok, source, state}

      :error ->
        case load_referenced_source(reference, state.step) do
          {:ok, source} ->
            {:ok, source, cache_source(state, cache_key, source)}

          {:error, :not_found} when kind == :file ->
            source = missing_source(external_id, decoded.mime_type)
            {:ok, source, cache_source(state, cache_key, source)}

          {:error, :not_found} ->
            resolve_source_by_sha(decoded, state, cache_key)

          {:error, reason} ->
            {:error, {:resolve_legacy_image_source_failed, reference, reason}, state}
        end
    end
  end

  defp resolve_source(nil, decoded, state) do
    resolve_source_by_sha(decoded, state, {:sha256, decoded.sha256})
  end

  defp resolve_source_by_sha(decoded, state, cache_key) do
    case Map.fetch(state.source_cache, cache_key) do
      {:ok, source} ->
        {:ok, source, state}

      :error ->
        case unique_scoped_source_by_sha(decoded.sha256, state.step) do
          {:ok, source} ->
            {:ok, source, cache_source(state, cache_key, source)}

          {:error, reason} ->
            {:error, {:legacy_image_source_not_resolved, decoded.sha256, reason}, state}
        end
    end
  end

  defp load_referenced_source(%{kind: :file, external_id: external_id}, step) do
    ChatMessageContent
    |> Ash.Query.filter(
      owner_id == ^step.owner_id and kind == :media and
        exists(file, external_id == ^external_id)
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, load: [:file])
    |> case do
      {:ok, %ChatMessageContent{file: %StoredFile{} = file}} -> {:ok, source_from_file(file)}
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_referenced_source(%{kind: :content, external_id: external_id}, step) do
    ChatMessageContent
    |> Ash.Query.filter(
      external_id == ^external_id and owner_id == ^step.owner_id and kind == :media
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, load: [:file])
    |> case do
      {:ok, %ChatMessageContent{file: %StoredFile{} = file}} -> {:ok, source_from_file(file)}
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unique_scoped_source_by_sha(sha256, step) do
    chat_ids =
      ContentFiles.handoff_chat_scope_ids(step.chat_message.chat_id, step.owner_id)

    ChatMessageContent
    |> Ash.Query.filter(
      owner_id == ^step.owner_id and kind == :media and exists(file, sha256 == ^sha256) and
        exists(
          chat_message_item.chat_message_step.chat_message,
          owner_id == ^step.owner_id and chat_id in ^chat_ids
        )
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.read(authorize?: false, load: [:file])
    |> case do
      {:ok, contents} ->
        sources =
          contents
          |> Enum.flat_map(fn
            %ChatMessageContent{file: %StoredFile{} = file} -> [source_from_file(file)]
            _content -> []
          end)
          |> Enum.uniq_by(& &1.external_id)

        case sources do
          [source] -> {:ok, source}
          [] -> {:error, :not_found}
          _sources -> {:error, :ambiguous}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_payload(decoded, source) do
    oversized? = max(decoded.width, decoded.height) > @max_edge_px
    source_matches? = is_binary(source.sha256) and source.sha256 == decoded.sha256

    variant_key =
      cond do
        oversized? -> @legacy_exact_variant
        source_matches? -> @identity_variant
        true -> @thumbnail_variant
      end

    {:ok,
     Map.merge(decoded, %{
       variant_key: variant_key,
       rendition_kind: if(oversized?, do: :legacy_exact, else: :fit),
       wire_changed?: false
     })}
  end

  defp put_descriptor(normalized, source, image, state) do
    descriptor = %{
      reference_key: source.external_id,
      source_file_external_id: source.external_id,
      source_sha256: source.sha256,
      filename: source.filename,
      payload: normalized.payload,
      sha256: normalized.sha256,
      mime_type: normalized.mime_type,
      variant_key: normalized.variant_key,
      rendition_kind: normalized.rendition_kind,
      encoded_chars: image.encoded_chars,
      wire_changed?: normalized.wire_changed?,
      missing_source?: source.missing?
    }

    case Map.fetch(state.descriptors, descriptor.reference_key) do
      :error ->
        {:ok,
         %{
           state
           | descriptors: Map.put(state.descriptors, descriptor.reference_key, descriptor),
             descriptor_order: state.descriptor_order ++ [descriptor.reference_key]
         }}

      {:ok, existing} ->
        if existing.sha256 == descriptor.sha256 and
             existing.source_file_external_id == descriptor.source_file_external_id do
          {:ok, state}
        else
          {:error, {:conflicting_legacy_request_image, descriptor.reference_key}}
        end
    end
  end

  defp apply_prepared(step, prepared) do
    case stage_files(step.id, prepared.descriptors) do
      {:ok, staged} ->
        case persist_staged(step, prepared, staged) do
          {:ok, used_file_ids} ->
            unused = Enum.reject(staged, &MapSet.member?(used_file_ids, &1.file.id))
            cleanup_errors = cleanup_staged_files(unused)
            {:ok, result(prepared, :migrated, cleanup_errors)}

          {:error, reason} ->
            cleanup_errors = cleanup_staged_files(staged)

            case cleanup_errors do
              [] -> {:error, reason}
              errors -> {:error, {:legacy_request_image_cleanup_failed, reason, errors}}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stage_files(step_id, descriptors) do
    Enum.reduce_while(descriptors, {:ok, []}, fn descriptor, {:ok, staged} ->
      filename = staged_filename(step_id, descriptor)

      case Files.create_from_binary(filename, descriptor.mime_type, descriptor.payload) do
        {:ok, file} ->
          {:cont, {:ok, [%{descriptor: descriptor, file: file} | staged]}}

        {:error, reason} ->
          cleanup_errors = cleanup_staged_files(staged)
          error = {:stage_legacy_request_image_failed, descriptor.reference_key, reason}

          if cleanup_errors == [] do
            {:halt, {:error, error}}
          else
            {:halt, {:error, {:legacy_request_image_cleanup_failed, error, cleanup_errors}}}
          end
      end
    end)
    |> case do
      {:ok, staged} -> {:ok, Enum.reverse(staged)}
      {:error, _reason} = error -> error
    end
  end

  defp persist_staged(step, prepared, staged) do
    Ash.transact(
      ChatMessageStep,
      fn ->
        with :ok <- enable_transaction_wal_compression(),
             {:ok, current} <- lock_step(step.id),
             :ok <- validate_current_step(current, step),
             {:ok, used_file_ids} <- attach_staged(current.id, staged),
             {:ok, _updated_step} <- persist_compact_request(current, prepared.compact_request) do
          used_file_ids
        end
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, %MapSet{} = used_file_ids} -> {:ok, used_file_ids}
      {:error, reason} -> {:error, {:persist_legacy_request_images_failed, step.id, reason}}
    end
  end

  defp enable_transaction_wal_compression do
    case Repo.query("SET LOCAL wal_compression = on", []) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:enable_wal_compression_failed, reason}}
    end
  end

  defp lock_step(step_id) do
    ChatMessageStep
    |> Ash.Query.filter(id == ^step_id)
    |> Ash.Query.select([:id, :status, :raw_request, :updated_at])
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %ChatMessageStep{} = step} -> {:ok, step}
      {:ok, nil} -> {:error, :step_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_current_step(current, original) do
    cond do
      current.status not in @terminal_statuses ->
        {:error, :step_became_active}

      current.updated_at != original.updated_at ->
        {:error, :step_changed_during_backfill}

      current.raw_request != original.raw_request ->
        {:error, :raw_request_changed_during_backfill}

      true ->
        :ok
    end
  end

  defp attach_staged(step_id, staged) do
    Enum.reduce_while(staged, {:ok, MapSet.new()}, fn staged_item, {:ok, used_file_ids} ->
      descriptor = staged_item.descriptor

      case binding_for_reference(step_id, descriptor.reference_key) do
        {:ok, %ChatMessageStepRequestFile{} = binding} ->
          case validate_existing_binding(binding, descriptor) do
            :ok -> {:cont, {:ok, used_file_ids}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:ok, nil} ->
          attrs = %{
            chat_message_step_id: step_id,
            file_id: staged_item.file.id,
            reference_key: descriptor.reference_key,
            source_file_external_id: descriptor.source_file_external_id,
            variant_key: descriptor.variant_key
          }

          case create_binding(attrs) do
            {:ok, _binding} ->
              {:cont, {:ok, MapSet.put(used_file_ids, staged_item.file.id)}}

            {:error, create_reason} ->
              case binding_for_reference(step_id, descriptor.reference_key) do
                {:ok, %ChatMessageStepRequestFile{} = winner} ->
                  case validate_existing_binding(winner, descriptor) do
                    :ok -> {:cont, {:ok, used_file_ids}}
                    {:error, reason} -> {:halt, {:error, reason}}
                  end

                {:ok, nil} ->
                  {:halt,
                   {:error,
                    {:create_legacy_request_image_binding_failed, descriptor.reference_key,
                     create_reason}}}

                {:error, lookup_reason} ->
                  {:halt,
                   {:error,
                    {:legacy_request_image_binding_conflict_lookup_failed,
                     descriptor.reference_key, create_reason, lookup_reason}}}
              end
          end

        {:error, reason} ->
          {:halt, {:error, {:load_legacy_request_image_binding_failed, reason}}}
      end
    end)
  end

  defp validate_existing_binding(binding, descriptor) do
    cond do
      to_string(binding.source_file_external_id) != descriptor.source_file_external_id ->
        {:error, {:legacy_request_image_binding_source_mismatch, descriptor.reference_key}}

      binding.variant_key != descriptor.variant_key ->
        {:error, {:legacy_request_image_binding_variant_mismatch, descriptor.reference_key}}

      not match?(%StoredFile{}, binding.file) ->
        {:error, {:legacy_request_image_binding_file_not_loaded, descriptor.reference_key}}

      binding.file.sha256 != descriptor.sha256 ->
        {:error, {:legacy_request_image_binding_payload_mismatch, descriptor.reference_key}}

      true ->
        :ok
    end
  end

  defp binding_for_reference(step_id, reference_key) do
    ChatMessageStepRequestFile
    |> Ash.Query.filter(chat_message_step_id == ^step_id and reference_key == ^reference_key)
    |> Ash.Query.load(:file)
    |> Ash.read_one(authorize?: false)
  end

  defp create_binding(attrs) do
    ChatMessageStepRequestFile
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create(authorize?: false)
  end

  defp persist_compact_request(step, compact_request) do
    step
    |> Ash.Changeset.for_update(:update, %{raw_request: compact_request}, authorize?: false)
    |> Ash.update(authorize?: false)
  end

  defp cleanup_staged_files(staged) do
    staged
    |> Enum.reduce([], fn staged_item, errors ->
      file_id = staged_item.file.id

      case Files.delete_file_and_maybe_payload(file_id) do
        :ok -> errors
        {:error, reason} -> [{file_id, reason} | errors]
      end
    end)
    |> Enum.reverse()
  end

  defp result(prepared, status, cleanup_errors) do
    identity_bindings =
      Enum.count(prepared.descriptors, &(&1.variant_key == @identity_variant))

    thumbnail_bindings =
      Enum.count(prepared.descriptors, &(&1.variant_key == @thumbnail_variant))

    legacy_exact_bindings =
      Enum.count(prepared.descriptors, &(&1.variant_key == @legacy_exact_variant))

    %{
      status: status,
      step_id: prepared.step_id,
      occurrences: prepared.occurrences,
      bindings: length(prepared.descriptors),
      encoded_chars: prepared.encoded_chars,
      decoded_bytes: prepared.decoded_bytes,
      legacy_json_bytes: prepared.legacy_json_bytes,
      compact_json_bytes: prepared.compact_json_bytes,
      identity_bindings: identity_bindings,
      thumbnail_bindings: thumbnail_bindings,
      legacy_exact_bindings: legacy_exact_bindings,
      missing_sources: prepared.missing_sources,
      wire_changed_oversized: prepared.wire_changed_oversized,
      payloads:
        Enum.map(prepared.descriptors, fn descriptor ->
          %{sha256: descriptor.sha256, bytes: byte_size(descriptor.payload)}
        end),
      cleanup_errors: cleanup_errors
    }
  end

  defp put_marker(:responses, block, marker, _mime_type) do
    Map.put(block, "image_url", marker)
  end

  defp put_marker(:openrouter, block, marker, _mime_type) do
    Map.update!(block, "image_url", &Map.put(&1, "url", marker))
  end

  defp put_marker(:anthropic, block, marker, mime_type) do
    source =
      block
      |> Map.get("source", %{})
      |> Map.put("type", "base64")
      |> Map.put("media_type", mime_type)
      |> Map.put("data", marker)

    Map.put(block, "source", source)
  end

  defp put_marker(:google, block, marker, mime_type) do
    block
    |> Map.put("mime_type", mime_type)
    |> Map.put("data", marker)
  end

  defp encoding_for_shape(shape) when shape in [:responses, :openrouter], do: :data_url
  defp encoding_for_shape(shape) when shape in [:anthropic, :google], do: :base64

  defp marker(%{rendition_kind: :fit} = image, external_id, encoding) do
    RequestImages.marker(external_id, image.mime_type, encoding)
  end

  defp marker(%{rendition_kind: :legacy_exact} = image, external_id, encoding) do
    RequestImages.legacy_exact_marker(external_id, image.mime_type, encoding)
  end

  defp load_step(step_id) do
    ChatMessageStep
    |> Ash.Query.filter(id == ^step_id)
    |> Ash.Query.select([
      :id,
      :status,
      :owner_id,
      :chat_message_id,
      :raw_request,
      :updated_at
    ])
    |> Ash.Query.load(chat_message: [:id, :chat_id])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %ChatMessageStep{} = step} -> {:ok, step}
      {:ok, nil} -> {:error, :step_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp source_from_file(file) do
    %{
      external_id: to_string(file.external_id),
      sha256: file.sha256,
      filename: file.filename,
      mime_type: file.mime_type,
      missing?: false
    }
  end

  defp missing_source(external_id, mime_type) do
    %{
      external_id: external_id,
      sha256: nil,
      filename: nil,
      mime_type: mime_type,
      missing?: true
    }
  end

  defp cache_source(state, cache_key, source) do
    %{state | source_cache: Map.put(state.source_cache, cache_key, source)}
  end

  defp staged_filename(step_id, descriptor) do
    suffix = image_suffix!(descriptor.mime_type)
    "#{@staged_filename_prefix}#{step_id}-#{descriptor.reference_key}#{suffix}"
  end

  defp image_suffix!(mime_type) do
    case image_suffix(mime_type) do
      {:ok, suffix} -> suffix
      {:error, _reason} -> ".img"
    end
  end

  defp image_suffix("image/png"), do: {:ok, ".png"}
  defp image_suffix("image/jpeg"), do: {:ok, ".jpg"}
  defp image_suffix("image/webp"), do: {:ok, ".webp"}
  defp image_suffix("image/gif"), do: {:ok, ".gif"}
  defp image_suffix("image/tiff"), do: {:ok, ".tiff"}
  defp image_suffix("image/bmp"), do: {:ok, ".bmp"}
  defp image_suffix(_mime_type), do: {:error, :unsupported_image_format}

  defp image_mime_type?(mime_type) when is_binary(mime_type),
    do: String.starts_with?(mime_type, "image/")

  defp image_mime_type?(_mime_type), do: false

  defp normalize_mime_type("image/jpg"), do: "image/jpeg"

  defp normalize_mime_type(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_mime_type(_value), do: nil

  defp sha256(payload),
    do: :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

  defp encoded_json_size(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _reason} -> 0
    end
  end
end
