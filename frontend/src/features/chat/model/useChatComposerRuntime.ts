import { computed, nextTick, ref, watch, type ComputedRef, type Ref } from 'vue';

import { api, getApiErrorMessage, isHttpError } from '@/api/client';
import {
  canTogglePendingImageOriginal,
  createPendingChatFiles,
  initialPendingImageState,
  isImageMimeType,
  overallPendingUploadProgress,
  pendingFileSizeError,
  pendingFileUploadTarget,
  pendingImageStateAfterConversion,
  pendingImageStateAfterInspection,
  pendingImageStatePatch,
  validateFilesForChatUpload,
  type ChatUploadPolicy,
  type PendingChatFile,
  type PendingImageState,
} from '@/features/chat/attachments';
import {
  convertImageFile,
  enqueueImageConversion,
  inspectImageFile,
  MODEL_IMAGE_LIMITS,
  type ImageUploadPlan,
} from '@/features/chat/imageNormalization';
import {
  abortChatUploadSession,
  createChatUploadSession,
  getChatUploadSession,
  isRetryableUploadChunkError,
  uploadChatChunk,
  UploadAbortedError,
  type ChatUploadInfo,
  type ChatUploadSessionOptions,
} from '@/features/chat/upload';
import {
  buildSendPayload,
  type ChatQueuedMessage,
  type PollResponse,
  type RuntimeCursor,
} from '@/features/chat/model/chatViewModel.shared';
import {
  generationPollDelay,
  selectRuntimeCursor,
  validRuntimeDelta,
  mergeRuntimePollContent,
  mergeRuntimeUsage,
  preserveStreamingMessageContent,
} from '@/features/chat/model/generationPolling';
import { useSyncedTextDraft, type DraftProblem, type DraftSubmission } from '@/features/app/useSyncedTextDraft';
import { useLocalTextDraft } from '@/features/app/useLocalTextDraft';
import { publishChatChange } from '@/features/chat/chatEvents';
import { translate } from '@/i18n';
import type { ChatBranchMessage } from '@/types/api';

type ScrollToLastMessage = (opts?: {
  behavior?: ScrollBehavior;
  block?: ScrollLogicalPosition;
}) => Promise<void> | void;

type Params = {
  chatId: ComputedRef<number>;
  branch: Ref<ChatBranchMessage[]>;
  readOnly: ComputedRef<boolean>;
  loadError: Ref<string>;
  fileUploadPolicy: ComputedRef<ChatUploadPolicy>;
  waitForConfigSync: (timeoutMs?: number) => Promise<boolean>;
  activeGenerationId: Ref<number | null>;
  cancelingGenerationId: Ref<number | null>;
  queuedMessages?: Ref<ChatQueuedMessage[]>;
  draftReady?: ComputedRef<boolean>;
  draftUserId?: ComputedRef<number | null>;
  draftOwned?: ComputedRef<boolean>;
  autoScrollEnabled?: ComputedRef<boolean>;
  scrollToLastMessage: ScrollToLastMessage;
  getOpenWorkingPollRequest?: (messageId: number) => string | null;
  getOpenWorkingPollSync?: (messageId: number) => string | undefined;
  getOpenWorkingPollRevision?: (messageId: number) => string | undefined;
  applyWorkingPoll?: (messageId: number, payload: PollResponse['working_open']) => void;
  onQueuedMessagesUpdated?: (messages: ChatQueuedMessage[]) => void;
  onQueuedMessageCreated?: (message: ChatQueuedMessage) => void;
  onGenerationSettled?: (messageId: number, status: string) => Promise<void> | void;
};

export function useChatComposerRuntime(params: Params) {
  const uploadChunkRetryDelaysMs = [500, 1_500];
  const pendingFiles = ref<PendingChatFile[]>([]);
  const draft = ref('');
  const sending = ref(false);
  const sendingMode = ref<'send' | 'queue' | 'continue' | null>(null);
  const steeringGenerationId = ref<number | null>(null);
  const generationPollReconnecting = ref(false);
  const draftReady = computed(() => params.draftReady?.value ?? true);
  const chatDraftStorageKey = computed(() => {
    const chatId = params.chatId.value;
    return chatId ? params.draftUserId
      ? `ic.draft.user.${params.draftUserId.value}.chat.${chatId}`
      : `ic.draft.chat.composer.${chatId}` : null;
  });
  watch(
    () => params.chatId.value,
    () => {
      if (params.draftUserId) return;
      draft.value = '';
    },
    { flush: 'sync' }
  );
  const chatDraftRevision = computed(() => {
    if (!draftReady.value || !params.chatId.value) return null;
    return 'composer-v2';
  });
  const chatTextDraft = useLocalTextDraft({
    storageKey: chatDraftStorageKey,
    revision: chatDraftRevision,
    value: draft,
    enabled: computed(() => !params.draftUserId && draftReady.value && Boolean(params.chatId.value) && !params.readOnly.value),
    isDraft: computed(() => draft.value !== '' && !params.readOnly.value && Boolean(params.chatId.value)),
    clearValueOnInvalidation: false,
  });

  const draftSync = useSyncedTextDraft({
    value: draft,
    accountId: params.draftUserId,
    target: computed(() => {
      const accountId = params.draftUserId?.value;
      const id = params.chatId.value;
      if (!accountId || !id || !draftReady.value || params.readOnly.value) return null;
      return {
        accountId,
        key: `ic.draft.user.${accountId}.chat.${id}`,
        endpoint: `/api/bff/chat-drafts/${id}`,
        ...(params.draftOwned?.value ? { legacyKey: `ic.draft.chat.composer.${id}` } : {}),
      };
    }),
    onSaved: (target) => {
      publishChatChange({ operation: 'touch', id: Number(target.endpoint.split('/').at(-1)), meta: { reason: 'draft-changed' } });
    },
  });
  // Routine save progress is deliberately silent; only problems with unsynchronized text are shown.
  const draftStatusLabel = computed(() => {
    const labels: Record<DraftProblem, string> = {
      offline: 'Saved on this device · Offline', error: 'Draft could not be synced',
      unprotected: 'Draft is not saved on this device', conflict: 'Draft changed on another device',
    };
    const problem = draftSync.problem.value;
    return problem ? translate(labels[problem]) : '';
  });

  const hasDraftText = computed(() => draft.value !== '');
  const hasSendPayload = computed(() => hasDraftText.value || pendingFiles.value.length > 0);
  const hasFollowUpBacklog = computed(() =>
    (params.queuedMessages?.value || []).some(
      (message) =>
        message.kind === 'follow_up' &&
        (message.status === 'pending' || message.status === 'blocked')
    )
  );
  const canSteerGeneration = computed(
    () => Boolean(params.activeGenerationId.value) && hasDraftText.value
  );

  const sendButtonLabel = computed(() => {
    if (sending.value) {
      if (sendingMode.value === 'continue') return translate('Continuing…');
      if (sendingMode.value === 'queue') return translate('Queueing…');

      const uploadProgress = overallPendingUploadProgress(pendingFiles.value);
      if (uploadProgress.active) {
        return translate('Uploading… {progress}%', {
          progress: Math.max(1, Math.round(uploadProgress.progress * 100)),
        });
      }

      if (pendingFiles.value.some((file) => pendingFileUploadTarget(file) === null)) {
        return translate('Preparing attachments…');
      }

      return translate('Sending…');
    }

    if (hasFollowUpBacklog.value) return translate('Queue');
    return hasSendPayload.value ? translate('Send') : translate('Continue');
  });

  const queueButtonLabel = computed(() =>
    sending.value && sendingMode.value === 'queue' ? translate('Queueing…') : translate('Queue')
  );

  const cancelButtonLabel = computed(() =>
    params.cancelingGenerationId.value === params.activeGenerationId.value
      ? translate('Cancelling…')
      : translate('Cancel')
  );

  const steerButtonLabel = computed(() =>
    steeringGenerationId.value === params.activeGenerationId.value
      ? translate('Steering…')
      : translate('Steer')
  );

  const errorMessage = (error: unknown, fallback: string) => getApiErrorMessage(error, fallback);

  const steeringErrorMessage = (error: unknown) => {
    if (isHttpError(error) && error.bodyJson && typeof error.bodyJson === 'object') {
      const code = (error.bodyJson as { code?: unknown }).code;
      const messageByCode: Record<string, string> = {
        empty_steering: 'Steering content must not be empty.',
        generation_not_active: 'Generation is no longer active.',
      };

      if (typeof code === 'string' && messageByCode[code]) {
        return translate(messageByCode[code]);
      }
    }

    return errorMessage(error, translate('Failed to steer generation.'));
  };

  const waitForAnimationFrame = () =>
    new Promise<void>((resolve) => {
      window.requestAnimationFrame(() => resolve());
    });

  const canAutoScroll = () => params.autoScrollEnabled?.value ?? true;
  const useLegacyAutoScroll = () => window.matchMedia('(max-width: 900px)').matches;

  const getPageScroller = () => document.scrollingElement || document.documentElement;

  const getMaxPageScrollTop = () => {
    const scroller = getPageScroller();
    return Math.max(0, scroller.scrollHeight - scroller.clientHeight);
  };

  const getVisiblePageBottom = () => {
    const viewport = window.visualViewport;
    if (
      viewport &&
      Number.isFinite(viewport.pageTop) &&
      Number.isFinite(viewport.height) &&
      viewport.height > 0
    ) {
      return viewport.pageTop + viewport.height;
    }

    const scroller = getPageScroller();
    return scroller.scrollTop + scroller.clientHeight;
  };

  const getFocusedComposer = () => {
    const activeElement = document.activeElement;
    if (!(activeElement instanceof HTMLElement)) return null;

    const composer = activeElement.closest<HTMLElement>('.chat-composer');
    if (!composer) return null;

    return { activeElement, composer };
  };

  const isPageScrolledToBottom = () => {
    if (!canAutoScroll()) return false;
    const scroller = getPageScroller();
    return scroller.scrollHeight - getVisiblePageBottom() <= 8;
  };

  const shouldKeepFocusedComposerVisible = () => {
    if (!canAutoScroll() || !useLegacyAutoScroll()) return false;
    const focusedComposer = getFocusedComposer();
    if (!focusedComposer) return false;

    const rect = focusedComposer.activeElement.getBoundingClientRect();
    const layoutViewportHeight = getPageScroller().clientHeight;

    return rect.bottom > 0 && rect.top < layoutViewportHeight;
  };

  const scrollFocusedComposerIntoView = () => {
    const focusedComposer = getFocusedComposer();
    if (!focusedComposer) return false;

    focusedComposer.composer.scrollIntoView({
      behavior: 'auto',
      block: 'nearest',
      inline: 'nearest',
    });
    return true;
  };

  const restoreAutoScrollPosition = (allowPageFallback: boolean) => {
    if (!useLegacyAutoScroll()) {
      if (allowPageFallback) {
        getPageScroller().scrollIntoView({ behavior: 'auto', block: 'end', inline: 'nearest' });
      }
      return;
    }

    if (scrollFocusedComposerIntoView()) return;
    if (!allowPageFallback) return;
    window.scrollTo({ top: getMaxPageScrollTop(), left: window.scrollX, behavior: 'auto' });
  };

  const keepAutoScrollPosition = async (allowPageFallback: boolean) => {
    if (!canAutoScroll()) return;
    await nextTick();
    await waitForAnimationFrame();
    if (!canAutoScroll()) return;
    restoreAutoScrollPosition(allowPageFallback);
    await waitForAnimationFrame();
    if (!canAutoScroll()) return;
    restoreAutoScrollPosition(allowPageFallback);
  };

  const findPendingFile = (filesRef: Ref<PendingChatFile[]>, id: string) =>
    filesRef.value.find((item) => item.id === id) || null;

  const updatePendingFile = (
    filesRef: Ref<PendingChatFile[]>,
    id: string,
    updater: Partial<PendingChatFile> | ((current: PendingChatFile) => Partial<PendingChatFile>)
  ) => {
    let nextItem: PendingChatFile | null = null;

    filesRef.value = filesRef.value.map((item) => {
      if (item.id !== id) return item;
      const patch = typeof updater === 'function' ? updater(item) : updater;
      nextItem = { ...item, ...patch };
      return nextItem;
    });

    return nextItem;
  };

  const syncPendingFileWithUpload = (
    filesRef: Ref<PendingChatFile[]>,
    id: string,
    upload: ChatUploadInfo,
    extra: Partial<PendingChatFile> = {}
  ) =>
    updatePendingFile(filesRef, id, (current) => {
      const uploadedBytes = Math.min(upload.uploaded_bytes || 0, current.size);
      const uploadStatus =
        upload.status === 'uploaded'
          ? 'uploaded'
          : upload.status === 'uploading'
            ? 'uploading'
            : 'error';

      return {
        uploadId: upload.upload_id,
        uploadStatus,
        uploadedBytes,
        progress: current.size > 0 ? uploadedBytes / current.size : 1,
        ...(uploadStatus === 'uploaded'
          ? { speedBps: 0, etaSeconds: 0, abortHandle: null }
          : {}),
        ...extra,
      };
    });

  const resolveChatUpload = async (
    chatIdValue: number,
    file: PendingChatFile,
    options: ChatUploadSessionOptions
  ) => {
    if (file.uploadId) {
      try {
        const upload = await getChatUploadSession(chatIdValue, file.uploadId);
        if (upload.status === 'uploading' || upload.status === 'uploaded') {
          return upload;
        }
      } catch (error) {
        if (!isHttpError(error) || error.status !== 404) throw error;
      }
    }

    return createChatUploadSession(chatIdValue, file.file, options);
  };

  const resolveWritableChatUpload = async (
    chatIdValue: number,
    file: PendingChatFile,
    options: ChatUploadSessionOptions
  ) => {
    let upload = await resolveChatUpload(chatIdValue, file, options);
    let offset = Math.min(upload.uploaded_bytes || 0, file.size);

    if (upload.status !== 'uploading' && upload.status !== 'uploaded') {
      upload = await createChatUploadSession(chatIdValue, file.file, options);
      offset = 0;
    }

    return { upload, offset };
  };

  const waitForUploadRetry = (delayMs: number) =>
    new Promise<void>((resolve) => {
      window.setTimeout(resolve, delayMs);
    });

  const abortUploadSessionQuietly = async (chatIdValue: number, uploadId: string) => {
    if (!chatIdValue) return;

    try {
      await abortChatUploadSession(chatIdValue, uploadId);
    } catch (error) {
      if (!isHttpError(error) || error.status !== 404) {
        console.warn('Failed to abort chat upload session', error);
      }
    }
  };

  const uploadPendingFile = async (
    filesRef: Ref<PendingChatFile[]>,
    fileId: string,
    chatIdValue: number,
    options: ChatUploadSessionOptions
  ) => {
    const pending = findPendingFile(filesRef, fileId);
    if (!pending) return null;

    // Removing the attachment or switching its variant (original/compressed) makes this
    // transfer stale: it then stops without touching the state of the attachment.
    const revision = pending.variantRevision ?? 0;
    const findLiveFile = () => {
      const item = findPendingFile(filesRef, fileId);
      return item && (item.variantRevision ?? 0) === revision ? item : null;
    };
    const updateLiveFile = (patch: Partial<PendingChatFile>) => {
      if (findLiveFile()) updatePendingFile(filesRef, fileId, patch);
    };
    const syncLiveFile = (upload: ChatUploadInfo, extra: Partial<PendingChatFile> = {}) => {
      if (findLiveFile()) syncPendingFileWithUpload(filesRef, fileId, upload, extra);
    };
    // A session that became stale before it was recorded on the attachment is aborted here;
    // recorded sessions are aborted by whoever removed or replaced the attachment.
    const resolveLiveUpload = async (file: PendingChatFile) => {
      const resolved = await resolveWritableChatUpload(chatIdValue, file, options);
      if (findLiveFile()) return resolved;
      void abortUploadSessionQuietly(chatIdValue, resolved.upload.upload_id);
      return null;
    };

    const initial = await resolveLiveUpload(pending);
    if (!initial) return null;
    let { upload, offset } = initial;

    syncLiveFile(upload, {
      error: '',
      speedBps: 0,
      etaSeconds: offset >= pending.size ? 0 : null,
    });

    if (upload.status === 'uploaded' || offset >= pending.size) {
      syncLiveFile(upload, {
        uploadStatus: 'uploaded',
        uploadedBytes: pending.size,
        progress: 1,
        speedBps: 0,
        etaSeconds: 0,
        abortHandle: null,
        error: '',
      });
      return upload.upload_id;
    }

    let resumeOffset = offset;
    let startedAt = performance.now();
    let retryAttempt = 0;

    while (offset < pending.size) {
      const liveFile = findLiveFile();
      if (!liveFile) return null;

      const chunkSize = Math.min(upload.chunk_size_bytes || liveFile.size, liveFile.size - offset);
      const chunk = liveFile.file.slice(offset, offset + chunkSize);

      try {
        upload = await uploadChatChunk(chatIdValue, upload.upload_id, offset, chunk, {
          onAbortHandle: (abortHandle) => {
            updateLiveFile({ abortHandle });
          },
          onProgress: (loadedBytes) => {
            const currentFile = findLiveFile();
            if (!currentFile) return;

            const totalUploaded = Math.min(offset + loadedBytes, currentFile.size);
            const elapsedSeconds = Math.max((performance.now() - startedAt) / 1000, 0.001);
            const transferredBytes = Math.max(totalUploaded - resumeOffset, 0);
            const speedBps = transferredBytes / elapsedSeconds;
            const remainingBytes = Math.max(currentFile.size - totalUploaded, 0);

            updatePendingFile(filesRef, fileId, {
              uploadId: upload.upload_id,
              uploadStatus: 'uploading',
              uploadedBytes: totalUploaded,
              progress: currentFile.size > 0 ? totalUploaded / currentFile.size : 1,
              speedBps,
              etaSeconds: speedBps > 0 ? remainingBytes / speedBps : null,
              error: '',
            });
          },
        });

        const currentFile = findLiveFile();
        if (!currentFile) return null;

        offset = Math.min(upload.uploaded_bytes || 0, currentFile.size);
        retryAttempt = 0;
        syncLiveFile(upload, {
          error: '',
          speedBps: offset >= currentFile.size ? 0 : currentFile.speedBps,
          etaSeconds: offset >= currentFile.size ? 0 : currentFile.etaSeconds,
          abortHandle: null,
        });
      } catch (error) {
        if (!findLiveFile()) return null;

        if (error instanceof UploadAbortedError) {
          updateLiveFile({
            uploadStatus: 'error',
            abortHandle: null,
            speedBps: 0,
            etaSeconds: null,
            error: 'Upload aborted.',
          });

          throw error;
        }

        if (isHttpError(error) && error.status === 409) {
          const nextOffset = Number((error.bodyJson as { next_offset?: unknown } | null)?.next_offset);

          if (Number.isFinite(nextOffset) && nextOffset >= 0) {
            const currentFile = findLiveFile();
            if (!currentFile) return null;

            offset = Math.min(nextOffset, currentFile.size);
            resumeOffset = offset;
            startedAt = performance.now();
            retryAttempt = 0;
            upload = await getChatUploadSession(chatIdValue, upload.upload_id);
            syncLiveFile(upload, {
              error: '',
              speedBps: 0,
              etaSeconds: null,
              abortHandle: null,
            });
            continue;
          }
        }

        if (isRetryableUploadChunkError(error) && retryAttempt < uploadChunkRetryDelaysMs.length) {
          const delayMs = uploadChunkRetryDelaysMs[retryAttempt];
          retryAttempt += 1;

          updateLiveFile({
            uploadStatus: 'uploading',
            abortHandle: null,
            speedBps: 0,
            etaSeconds: null,
            error: '',
          });

          await waitForUploadRetry(delayMs);

          const currentFile = findLiveFile();
          if (!currentFile) return null;

          try {
            const resumed = await resolveLiveUpload(currentFile);
            if (!resumed) return null;
            ({ upload, offset } = resumed);
          } catch (syncError) {
            if (!findLiveFile()) return null;

            updateLiveFile({
              uploadStatus: 'error',
              abortHandle: null,
              speedBps: 0,
              etaSeconds: null,
              error: errorMessage(syncError, 'Failed to resume attachment upload.'),
            });

            throw syncError;
          }

          resumeOffset = offset;
          startedAt = performance.now();
          syncLiveFile(upload, {
            error: '',
            speedBps: 0,
            etaSeconds: offset >= currentFile.size ? 0 : null,
            abortHandle: null,
          });
          continue;
        }

        updateLiveFile({
          uploadStatus: 'error',
          abortHandle: null,
          speedBps: 0,
          etaSeconds: null,
          error: errorMessage(error, 'Failed to upload attachment.'),
        });

        throw error;
      }
    }

    const finalFile = findLiveFile();
    if (!finalFile) return null;

    updatePendingFile(filesRef, fileId, {
      uploadId: upload.upload_id,
      uploadStatus: 'uploaded',
      uploadedBytes: finalFile.size,
      progress: 1,
      speedBps: 0,
      etaSeconds: 0,
      abortHandle: null,
      error: '',
    });

    return upload.upload_id;
  };

  // Image preparations in flight, keyed by pending file id; uploads wait for them. Each one
  // resolves to the error its attachment was rejected with, or '' when it was kept.
  const imagePreparations = new Map<string, Promise<string>>();

  const ensurePendingFilesUploaded = async (
    filesRef: Ref<PendingChatFile[]>,
    fileIds?: ReadonlySet<string>,
    options: ChatUploadSessionOptions = {}
  ) => {
    if (!params.chatId.value) return [];

    const targetIds = fileIds ? [...fileIds] : filesRef.value.map((item) => item.id);

    for (const fileId of targetIds) {
      // Repeats when the attachment switches to another variant while it is uploaded.
      for (;;) {
        const item = findPendingFile(filesRef, fileId);
        if (!item) break;

        const preparation = imagePreparations.get(fileId);
        if (preparation && pendingFileUploadTarget(item) === null) {
          const rejection = await preparation;
          if (rejection) throw new Error(rejection);
          continue;
        }

        if (item.uploadStatus === 'uploaded' && item.uploadId) break;

        const revision = item.variantRevision ?? 0;
        const isCurrentVariant = () => (findPendingFile(filesRef, fileId)?.variantRevision ?? 0) === revision;

        try {
          await uploadPendingFile(filesRef, fileId, params.chatId.value, options);
        } catch (error) {
          if (error instanceof UploadAbortedError && (!findPendingFile(filesRef, fileId) || !isCurrentVariant())) {
            continue;
          }

          throw error;
        }

        const updated = findPendingFile(filesRef, fileId);
        if (!updated) break;
        if (!isCurrentVariant()) continue;
        if (updated.uploadStatus === 'uploaded' && updated.uploadId) break;

        throw new Error(updated.error || 'Failed to upload attachment.');
      }
    }

    return filesRef.value
      .filter((item) => !fileIds || fileIds.has(item.id))
      .map((item) => item.uploadId)
      .filter((value): value is string => typeof value === 'string' && value.trim() !== '');
  };

  // Applies a new image state; switching the uploaded variant drops the previous upload.
  const replacePendingImageState = (
    filesRef: Ref<PendingChatFile[]>,
    id: string,
    image: PendingImageState | null
  ) => {
    const current = findPendingFile(filesRef, id);
    if (!current) return;

    const { patch, variantChanged } = pendingImageStatePatch(current, image);
    updatePendingFile(filesRef, id, patch);
    if (!variantChanged) return;

    current.abortHandle?.();
    if (current.uploadId) void abortUploadSessionQuietly(params.chatId.value, current.uploadId);
  };

  /**
   * Applies the next image state of an attachment being prepared. When the variant that
   * state uploads exceeds the size limit, the attachment is removed instead and the
   * error is returned; otherwise ''.
   */
  const settlePendingImageState = (
    filesRef: Ref<PendingChatFile[]>,
    id: string,
    update: (image: PendingImageState) => PendingImageState | null,
    sizeLimitBytes: number
  ) => {
    const current = findPendingFile(filesRef, id);
    if (!current?.image) return '';

    const image = update(current.image);
    const error = pendingFileSizeError({ ...current, image }, sizeLimitBytes);
    if (error) void removePendingFileFromCollection(filesRef, id);
    else replacePendingImageState(filesRef, id, image);
    return error;
  };

  const preparePendingFile = async (
    filesRef: Ref<PendingChatFile[]>,
    id: string,
    source: File,
    sizeLimitBytes: number
  ) => {
    let plan: ImageUploadPlan | null = null;
    try {
      plan = await inspectImageFile(source);
    } catch (error) {
      console.warn('Failed to inspect attachment', error);
    }

    // Not a raster image this client can prepare (SVG, icon, damaged file): upload it as is.
    if (!plan) return settlePendingImageState(filesRef, id, () => null, sizeLimitBytes);

    const inspected = plan;
    const rejection = settlePendingImageState(
      filesRef,
      id,
      (image) => pendingImageStateAfterInspection(image, inspected),
      sizeLimitBytes
    );
    if (rejection || inspected.action !== 'convert') return rejection;

    // The copy has to fit the upload policy as well. Conversions run one at a time; skip
    // those of attachments removed while waiting.
    const limits = { ...MODEL_IMAGE_LIMITS, maxBytes: Math.min(MODEL_IMAGE_LIMITS.maxBytes, sizeLimitBytes) };
    const result = await enqueueImageConversion(async () =>
      findPendingFile(filesRef, id) ? convertImageFile(source, inspected, { limits }) : null
    );
    if (!result) return '';
    if (result.kind === 'failed') {
      console.warn(`Failed to ${result.reason} image attachment ${JSON.stringify(source.name)}`, result.error);
    }

    return settlePendingImageState(
      filesRef,
      id,
      (image) => pendingImageStateAfterConversion(image, result),
      sizeLimitBytes
    );
  };

  /**
   * Adds the files the upload policy accepts to an attachment collection and starts
   * preparing the images among them (the server treats only image MIME types as images).
   * An image over the size limit is accepted while a compressed copy may fit; it is
   * removed with the usual size error once the variant to upload turns out too large.
   * `setError` gets the first rejection, '' when every file was accepted, and later the
   * error of such a removal.
   */
  const addPendingFilesToCollection = (
    filesRef: Ref<PendingChatFile[]>,
    files: File[],
    policy: ChatUploadPolicy,
    setError: (error: string) => void
  ) => {
    const { accepted, errors } = validateFilesForChatUpload(files, policy, { deferImageSizeCheck: true });
    const sizeLimitBytes = policy.maxFileSizeBytes;
    const created = createPendingChatFiles(accepted).map((item) =>
      isImageMimeType(item.file.type) ? { ...item, image: initialPendingImageState(item.file, sizeLimitBytes) } : item
    );
    if (created.length > 0) filesRef.value = [...filesRef.value, ...created];
    setError(errors[0] || '');

    for (const item of created) {
      if (!item.image) continue;
      const preparation = preparePendingFile(filesRef, item.id, item.file, sizeLimitBytes)
        .catch((error) => {
          console.error('Failed to prepare attachment', error);
          return settlePendingImageState(
            filesRef,
            item.id,
            (image) => ({ ...image, phase: 'ready', failed: true }),
            sizeLimitBytes
          );
        })
        .then((rejection) => {
          if (rejection) setError(rejection);
          return rejection;
        })
        .finally(() => imagePreparations.delete(item.id));
      imagePreparations.set(item.id, preparation);
    }
  };

  /** Chooses between the original image and its compressed copy for upload. */
  const setPendingFileOriginalInCollection = (
    filesRef: Ref<PendingChatFile[]>,
    id: string,
    keepOriginal: boolean
  ) => {
    const image = findPendingFile(filesRef, id)?.image;
    if (!image || image.keepOriginal === keepOriginal || !canTogglePendingImageOriginal(image)) return;
    replacePendingImageState(filesRef, id, { ...image, keepOriginal });
  };

  const removePendingFileFromCollection = async (filesRef: Ref<PendingChatFile[]>, id: string) => {
    const current = findPendingFile(filesRef, id);
    if (!current) return;

    current.abortHandle?.();
    filesRef.value = filesRef.value.filter((item) => item.id !== id);

    if (!params.chatId.value || !current.uploadId) return;

    await abortUploadSessionQuietly(params.chatId.value, current.uploadId);
  };

  const clearPendingFilesCollection = async (filesRef: Ref<PendingChatFile[]>) => {
    const snapshot = [...filesRef.value];
    filesRef.value = [];

    for (const item of snapshot) {
      item.abortHandle?.();

      if (!params.chatId.value || !item.uploadId) continue;

      await abortUploadSessionQuietly(params.chatId.value, item.uploadId);
    }
  };

  const generatingMessageIdInBranch = computed<number | null>(() => {
    const list = params.branch.value || [];
    for (let i = list.length - 1; i >= 0; i -= 1) {
      const message = list[i];
      if (message?.status === 'generating') return message.id;
    }
    return null;
  });

  let pollTimer: number | null = null;
  let pollingToken = 0;
  let pollingChatId: number | null = null;
  let pollAbortController: AbortController | null = null;
  let lastResumeSyncAt = 0;
  let pollRevision: string | undefined;
  let contentRevision: string | undefined;
  let runtimeRevision: string | undefined;
  let viewRevision: string | undefined;
  let synchronizedWorkingSync: string | undefined;
  let runtimeCursor: RuntimeCursor | null | undefined;
  let pollDelayMs = 500;
  let consecutivePollErrors = 0;

  const resetPollRevisions = () => {
    pollRevision = undefined;
    contentRevision = undefined;
    runtimeRevision = undefined;
    viewRevision = undefined;
    synchronizedWorkingSync = undefined;
    runtimeCursor = undefined;
  };

  const stopPolling = (opts: { resetConnectionState?: boolean } = {}) => {
    const resetConnectionState = opts.resetConnectionState ?? true;
    pollingToken += 1;
    pollingChatId = null;
    resetPollRevisions();
    pollDelayMs = 500;
    consecutivePollErrors = 0;
    if (pollTimer != null) {
      window.clearTimeout(pollTimer);
      pollTimer = null;
    }
    if (pollAbortController) {
      pollAbortController.abort();
      pollAbortController = null;
    }

    if (resetConnectionState) generationPollReconnecting.value = false;
  };

  const updateBranchMessage = (messageId: number, patch: Partial<ChatBranchMessage>) => {
    const idx = params.branch.value.findIndex((item) => item.id === messageId);
    if (idx === -1) return;
    params.branch.value[idx] = { ...params.branch.value[idx], ...patch };
  };

  const pollOnce = async (messageId: number, token: number) => {
    const controller = new AbortController();
    pollAbortController = controller;
    const branchAtRequest = params.branch.value;
    const chatAtRequest = params.chatId.value;

    let didTimeout = false;
    const timeoutHandle = window.setTimeout(() => {
      didTimeout = true;
      controller.abort();
    }, 25_000);

    try {
      const searchParams = new URLSearchParams({ poll_protocol: 'cursor' });
      const cursorAtRequest = runtimeCursor;
      if (runtimeCursor) searchParams.set('runtime_cursor', JSON.stringify(runtimeCursor));
      if (viewRevision) searchParams.set('view_revision', viewRevision);
      const workingStepId = params.getOpenWorkingPollRequest?.(messageId);
      const workingSync = params.getOpenWorkingPollSync?.(messageId);
      if (workingStepId) {
        if (workingSync) searchParams.set('working_sync', workingSync);
        searchParams.set('working_step_id', workingStepId);
        const workingRevision = params.getOpenWorkingPollRevision?.(messageId);
        // The first projection must align inspector and body, even if /working
        // happened to return the same revision as a previous poll snapshot.
        if (workingRevision && workingSync === synchronizedWorkingSync) {
          searchParams.set('working_revision', workingRevision);
        }
      }
      if (pollRevision) searchParams.set('revision', pollRevision);
      if (contentRevision) searchParams.set('content_revision', contentRevision);
      if (runtimeRevision) searchParams.set('runtime_revision', runtimeRevision);
      const suffix = searchParams.toString() ? `?${searchParams.toString()}` : '';

      const response = await api.get<PollResponse | undefined>(
        `/api/bff/chat-messages/${messageId}/poll${suffix}`,
        {
          signal: controller.signal,
          showErrorBanner: false,
          timeoutMs: null,
          retry: false,
        }
      );

      if (pollingToken !== token) return false;
      generationPollReconnecting.value = false;
      consecutivePollErrors = 0;
      // A full reload owns the new branch. Discard even a previously valid 204.
      if (params.branch.value !== branchAtRequest) return true;
      if (!response) return true;
      if (response.runtime_delta && !validRuntimeDelta(cursorAtRequest, response.runtime_delta)) {
        resetPollRevisions();
        return true;
      }
      pollDelayMs = generationPollDelay(response);

      if (Array.isArray(response.queued_messages)) {
        params.onQueuedMessagesUpdated?.(response.queued_messages);
      }

      const current = params.branch.value.find((item) => item.id === messageId) || null;
      const shouldKeepPageAtBottom = current ? isPageScrolledToBottom() : false;
      const keepFocusedComposerVisible = current ? shouldKeepFocusedComposerVisible() : false;

      if (current) {
        const patch: Partial<ChatBranchMessage> = {
          status: response.status as ChatBranchMessage['status'],
          finished_at: response.finished_at ?? undefined,
          error_detail: response.error_detail ?? undefined,
        };

        if (typeof response.token_count === 'number') {
          patch.token_count = response.token_count;
        }

        if (response.content !== undefined || response.runtime_content !== undefined || response.runtime_delta) {
          patch.content = mergeRuntimePollContent(current.content, response);
        }
        if (response.usage) patch.usage = response.usage;
        else if (response.runtime_summary) {
          patch.usage = mergeRuntimeUsage(current.usage, response.runtime_summary);
        }
        if (response.working) patch.working = response.working;

        updateBranchMessage(messageId, patch);
        const sameWorkingSession = Boolean(workingStepId) &&
          workingStepId === params.getOpenWorkingPollRequest?.(messageId) &&
          workingSync === params.getOpenWorkingPollSync?.(messageId);
        if (sameWorkingSession) {
          if (response.working_open !== undefined) {
            params.applyWorkingPoll?.(messageId, response.working_open);
            synchronizedWorkingSync = workingSync;
          }
          if (response.runtime_delta || response.runtime_summary) {
            params.applyWorkingPoll?.(messageId, {
              runtime_delta: response.runtime_delta, runtime_summary: response.runtime_summary,
            });
          }
        }
        // A cursor acknowledges only data that was successfully applied to this branch.
        pollRevision = response.revision;
        contentRevision = response.content_revision;
        runtimeRevision = response.runtime_revision;
        viewRevision = response.view_revision;
        runtimeCursor = selectRuntimeCursor(response);
        if (shouldKeepPageAtBottom || keepFocusedComposerVisible) {
          void keepAutoScrollPosition(shouldKeepPageAtBottom);
        }
      }

      const doneStatuses = new Set(['done', 'canceled', 'error']);
      if (doneStatuses.has(response.status)) {
        const nextGenerationId =
          typeof response.active_generation_message_id === 'number' &&
          response.active_generation_message_id !== messageId
            ? response.active_generation_message_id
            : null;
        if (params.activeGenerationId.value === messageId) params.activeGenerationId.value = null;
        if (params.cancelingGenerationId.value === messageId)
          params.cancelingGenerationId.value = null;
        stopPolling();
        const terminalToken = pollingToken;
        await params.onGenerationSettled?.(messageId, response.status);
        // Reload may await navigation or a newly started generation. The old
        // continuation must not take ownership of that route's polling session.
        if (pollingToken !== terminalToken || params.chatId.value !== chatAtRequest) return false;
        if (nextGenerationId && params.activeGenerationId.value !== nextGenerationId) {
          void startPolling(nextGenerationId);
        }
        if (params.chatId.value) {
          publishChatChange({
            operation: 'touch',
            id: params.chatId.value,
            meta: { reason: 'generation-settled', status: response.status },
          });
        }
        return false;
      }

      return true;
    } catch (error) {
      resetPollRevisions();
      if (didTimeout && error instanceof DOMException && error.name === 'AbortError') {
        throw new Error('Generation poll timed out.');
      }

      throw error;
    } finally {
      window.clearTimeout(timeoutHandle);
      if (pollAbortController === controller) pollAbortController = null;
    }
  };

  const startPolling = async (messageId: number) => {
    // A scalar polling session belongs only to the visible branch.
    if (!params.branch.value.some((message) => message.id === messageId && message.status === 'generating')) return;
    const sameGeneration = params.activeGenerationId.value === messageId;
    stopPolling({ resetConnectionState: !sameGeneration });
    params.activeGenerationId.value = messageId;
    pollingChatId = params.chatId.value;
    if (params.chatId.value) {
      publishChatChange({
        operation: 'touch',
        id: params.chatId.value,
        patch: { active_generation_message_id: messageId },
        meta: { reason: 'generation-start' },
      });
    }

    const token = pollingToken;

    const tick = async () => {
      if (pollingToken !== token) return;
      try {
        const keepGoing = await pollOnce(messageId, token);
        if (keepGoing && params.activeGenerationId.value === messageId && pollingToken === token) {
          pollTimer = window.setTimeout(tick, pollDelayMs);
        }
      } catch (error) {
        if (pollingToken !== token) return;
        if (error instanceof DOMException && error.name === 'AbortError') return;
        console.warn(error);
        generationPollReconnecting.value = true;
        consecutivePollErrors += 1;
        if (params.activeGenerationId.value === messageId && pollingToken === token) {
          pollTimer = window.setTimeout(
            tick,
            Math.min(1500 * 2 ** (consecutivePollErrors - 1), 10_000)
          );
        }
      }
    };

    await tick();
  };

  watch(() => params.branch.value, (next, previous) => {
    resetPollRevisions();
    if (pollingChatId !== params.chatId.value || params.activeGenerationId.value == null) return;
    const messageId = params.activeGenerationId.value;
    const index = next.findIndex((message) => message.id === messageId);
    if (index === -1) {
      params.activeGenerationId.value = null;
      params.cancelingGenerationId.value = null;
      stopPolling();
      return;
    }
    const current = previous.find((message) => message.id === messageId);
    // Merge synchronously, before Vue can render the persisted-only replacement.
    next[index] = preserveStreamingMessageContent(current, next[index]!);
  }, { flush: 'sync' });
  watch(
    () => params.chatId.value,
    () => {
      params.activeGenerationId.value = null;
      params.cancelingGenerationId.value = null;
      stopPolling();
    },
    { flush: 'sync' }
  );

  watch(
    () => generatingMessageIdInBranch.value,
    (messageId) => {
      if (messageId) {
        if (params.activeGenerationId.value !== messageId) {
          void startPolling(messageId);
        }
      } else if (params.activeGenerationId.value != null) {
        params.activeGenerationId.value = null;
        params.cancelingGenerationId.value = null;
        stopPolling();
      }
    }
  );

  const resumeSyncIfNeeded = () => {
    const messageId = params.activeGenerationId.value || generatingMessageIdInBranch.value;
    if (!messageId) return;

    const now = Date.now();
    if (now - lastResumeSyncAt < 1000) return;
    lastResumeSyncAt = now;

    void startPolling(messageId);
  };

  const handleVisibilityChange = () => {
    if (document.visibilityState !== 'visible') return;
    resumeSyncIfNeeded();
  };

  const handlePageShow = () => {
    resumeSyncIfNeeded();
  };

  const handleFocus = () => {
    resumeSyncIfNeeded();
  };

  type GenerationStartPayload = {
    branch: ChatBranchMessage[];
    generation: { message_id: number };
  };

  type QueuedMessagePayload = {
    queued_message: ChatQueuedMessage;
  };

  const applyGenerationStart = async (payload: GenerationStartPayload) => {
    params.branch.value = payload.branch || [];

    const messageId = payload.generation?.message_id;
    if (messageId) {
      await startPolling(messageId);
    }

    if (canAutoScroll()) {
      void params.scrollToLastMessage({ behavior: 'smooth', block: 'end' });
    }
  };

  const apiErrorCode = (error: unknown) => {
    if (!isHttpError(error) || !error.bodyJson || typeof error.bodyJson !== 'object') return null;
    const code = (error.bodyJson as { code?: unknown }).code;
    return typeof code === 'string' ? code : null;
  };

  const queueErrorMessage = (error: unknown) => {
    const code = apiErrorCode(error);
    const messageByCode: Record<string, string> = {
      empty_message: 'A queued message must contain text or an attachment.',
      invalid_file_ids: 'Some queued attachments are no longer available.',
      queue_not_empty: 'The message was added after the existing queue.',
      generation_active: 'The message was added after the active generation.',
    };
    if (code && messageByCode[code]) return translate(messageByCode[code]);
    return errorMessage(error, translate('Failed to queue message.'));
  };

  const clearAcknowledgedComposerSnapshot = (
    content: string,
    pendingFileIds: ReadonlySet<string>,
    storageKey: string | null
  ) => {
    if (chatDraftStorageKey.value !== storageKey) {
      // A late acknowledgement must not mutate another chat's composer.
      // Remove the original persisted snapshot only if it has not been edited.
      try {
        const stored = storageKey ? window.localStorage.getItem(storageKey) : null;
        if (!params.draftUserId && stored && JSON.parse(stored)?.text === content) chatTextDraft.clear(storageKey);
      } catch {
        // Ignore unavailable storage or malformed drafts.
      }
      return;
    }
    if (draft.value === content) draft.value = '';
    if (pendingFileIds.size > 0) {
      pendingFiles.value = pendingFiles.value.filter((file) => !pendingFileIds.has(file.id));
    }
    if (!params.draftUserId && draft.value === '') chatTextDraft.clear(storageKey);
  };

  const createQueuedMessage = async (
    content: string,
    uploadIds: string[],
    draftRevision?: number
  ) => {
    const payload = await api.post<QueuedMessagePayload>(
      `/api/bff/chat-generation/${params.chatId.value}/queue`,
      { ...buildSendPayload(content, uploadIds), ...(draftRevision !== undefined ? { draft_revision: draftRevision } : {}) }
    );
    if (payload.queued_message) params.onQueuedMessageCreated?.(payload.queued_message);
    if (params.chatId.value) {
      publishChatChange({
        operation: 'touch',
        id: params.chatId.value,
        meta: { reason: 'queue-created' },
      });
    }
    return payload;
  };

  const sendMessage = async () => {
    if (params.readOnly.value) return;
    if (!params.chatId.value || sending.value) return;
    if (params.activeGenerationId.value) return;
    if (!hasSendPayload.value) return;

    const requestedChatId = params.chatId.value;
    const parentId = params.branch.value.at(-1)?.id ?? null;
    // A data refresh preserves the leaf; only a different chat or path invalidates the action.
    const isCurrentBranch = () => params.chatId.value === requestedChatId &&
      (params.branch.value.at(-1)?.id ?? null) === parentId;
    const draftStorageKeyBeforeSend = chatDraftStorageKey.value;
    let draftSubmission: DraftSubmission | undefined;
    let draftAccepted = false;
    const content = draft.value;
    const pendingFileIds = new Set(pendingFiles.value.map((file) => file.id));
    sending.value = true;
    sendingMode.value = 'send';
    params.loadError.value = '';

    try {
      const configReady = await params.waitForConfigSync();
      if (!configReady) {
        params.loadError.value = translate('Configuration change is still syncing. Please wait.');
        return;
      }

      if (!isCurrentBranch()) return;
      const hasUserText = content !== '';
      const uploadIds = pendingFileIds.size > 0
        ? await ensurePendingFilesUploaded(pendingFiles, pendingFileIds)
        : [];
      const hasPendingFiles = uploadIds.length > 0;
      if (!hasUserText && !hasPendingFiles) return;

      if (!isCurrentBranch()) return;

      if (params.draftUserId) draftSubmission = await draftSync.beginSubmission(content);
      if (!isCurrentBranch()) return;
      let payload: GenerationStartPayload;
      try {
        payload = await api.post<GenerationStartPayload>(
          `/api/bff/chat-generation/${requestedChatId}/send`,
          { ...buildSendPayload(content, uploadIds), parent_id: parentId,
            ...(draftSubmission?.revision !== undefined ? { draft_revision: draftSubmission.revision } : {}) }
        );
      } catch (error) {
        if (!isCurrentBranch()) return;
        if (
          isHttpError(error) &&
          error.status === 409 &&
          ['queue_not_empty', 'generation_active'].includes(apiErrorCode(error) || '')
        ) {
          sendingMode.value = 'queue';
          await createQueuedMessage(content, uploadIds, draftSubmission?.revision);
          draftAccepted = true;
          clearAcknowledgedComposerSnapshot(content, pendingFileIds, draftStorageKeyBeforeSend);
          return;
        }
        throw error;
      }

      draftAccepted = true;
      // Acceptance owns the submitted snapshot, not the currently visible history.
      clearAcknowledgedComposerSnapshot(content, pendingFileIds, draftStorageKeyBeforeSend);
      if (!isCurrentBranch()) return;

      await applyGenerationStart(payload);
    } catch (error) {
      console.error(error);
      params.loadError.value = [
        'empty_message',
        'invalid_file_ids',
        'queue_not_empty',
        'generation_active',
      ].includes(apiErrorCode(error) || '')
        ? queueErrorMessage(error)
        : errorMessage(error, translate('Failed to send message.'));
    } finally {
      if (draftSubmission) void draftSync.finishSubmission(draftSubmission, draftAccepted);
      sending.value = false;
      sendingMode.value = null;
    }
  };

  const queueMessage = async () => {
    if (params.readOnly.value || !params.chatId.value || sending.value || !hasSendPayload.value) return;

    const content = draft.value;
    const pendingFileIds = new Set(pendingFiles.value.map((file) => file.id));
    const draftStorageKeyBeforeQueue = chatDraftStorageKey.value;
    const requestedChatId = params.chatId.value;
    let draftSubmission: DraftSubmission | undefined;
    let draftAccepted = false;
    sending.value = true;
    sendingMode.value = 'queue';
    params.loadError.value = '';

    try {
      const configReady = await params.waitForConfigSync();
      if (!configReady) {
        params.loadError.value = translate('Configuration change is still syncing. Please wait.');
        return;
      }

      const uploadIds = pendingFileIds.size > 0
        ? await ensurePendingFilesUploaded(pendingFiles, pendingFileIds)
        : [];
      if (content === '' && uploadIds.length === 0) return;

      if (params.chatId.value !== requestedChatId) return;
      if (params.draftUserId) draftSubmission = await draftSync.beginSubmission(content);
      if (params.chatId.value !== requestedChatId) return;
      await createQueuedMessage(content, uploadIds, draftSubmission?.revision);
      draftAccepted = true;
      clearAcknowledgedComposerSnapshot(content, pendingFileIds, draftStorageKeyBeforeQueue);
    } catch (error) {
      console.error(error);
      params.loadError.value = queueErrorMessage(error);
    } finally {
      if (draftSubmission) void draftSync.finishSubmission(draftSubmission, draftAccepted);
      sending.value = false;
      sendingMode.value = null;
    }
  };

  const continueGeneration = async () => {
    if (params.readOnly.value) return;
    if (!params.chatId.value || sending.value) return;
    if (params.activeGenerationId.value || hasSendPayload.value) return;

    const requestedChatId = params.chatId.value;
    const parentId = params.branch.value.at(-1)?.id ?? null;
    // A data refresh preserves the leaf; only a different chat or path invalidates the action.
    const isCurrentBranch = () => params.chatId.value === requestedChatId &&
      (params.branch.value.at(-1)?.id ?? null) === parentId;

    sending.value = true;
    sendingMode.value = 'continue';
    params.loadError.value = '';

    try {
      const configReady = await params.waitForConfigSync();
      if (!configReady) {
        params.loadError.value = translate('Configuration change is still syncing. Please wait.');
        return;
      }

      if (!isCurrentBranch()) return;
      const payload = await api.post<GenerationStartPayload>(
        `/api/bff/chat-generation/${requestedChatId}/generate`,
        { parent_id: parentId }
      );
      if (!isCurrentBranch()) return;
      await applyGenerationStart(payload);
    } catch (error) {
      console.error(error);
      params.loadError.value = errorMessage(error, translate('Failed to send message.'));
    } finally {
      sending.value = false;
      sendingMode.value = null;
    }
  };

  const steerGeneration = async () => {
    if (params.readOnly.value) return;
    const messageId = params.activeGenerationId.value;
    if (!messageId || !canSteerGeneration.value) return;
    if (steeringGenerationId.value || params.cancelingGenerationId.value === messageId) return;

    const content = draft.value;
    if (content === '') return;

    const draftStorageKeyBeforeSteer = chatDraftStorageKey.value;
    let draftSubmission: DraftSubmission | undefined;
    let draftAccepted = false;
    steeringGenerationId.value = messageId;
    params.loadError.value = '';

    try {
      if (params.draftUserId) draftSubmission = await draftSync.beginSubmission(content);
      if (chatDraftStorageKey.value !== draftStorageKeyBeforeSteer) return;
      const payload = await api.post<QueuedMessagePayload>(
        `/api/bff/chat-messages/${messageId}/steer`,
        { content, ...(draftSubmission?.revision !== undefined ? { draft_revision: draftSubmission.revision } : {}) }
      );

      if (payload.queued_message) params.onQueuedMessageCreated?.(payload.queued_message);

      draftAccepted = true;
      if (chatDraftStorageKey.value === draftStorageKeyBeforeSteer && draft.value === content) {
        draft.value = '';
        if (!params.draftUserId) chatTextDraft.clear(draftStorageKeyBeforeSteer);
      }

      if (params.activeGenerationId.value === messageId) {
        void startPolling(messageId);
      }
    } catch (error) {
      console.error(error);
      params.loadError.value = steeringErrorMessage(error);
    } finally {
      if (draftSubmission) void draftSync.finishSubmission(draftSubmission, draftAccepted);
      if (steeringGenerationId.value === messageId) steeringGenerationId.value = null;
    }
  };

  const submitComposer = async () => {
    if (params.activeGenerationId.value) {
      if (canSteerGeneration.value) await steerGeneration();
      return;
    }

    if (hasFollowUpBacklog.value && hasSendPayload.value) {
      await queueMessage();
      return;
    }

    if (hasSendPayload.value) {
      await sendMessage();
      return;
    }

    if (hasFollowUpBacklog.value) return;

    await continueGeneration();
  };

  const cancelActiveGeneration = async () => {
    if (params.readOnly.value) return;
    const messageId = params.activeGenerationId.value;
    if (!messageId || params.cancelingGenerationId.value === messageId) return;
    if (steeringGenerationId.value === messageId) return;
    params.cancelingGenerationId.value = messageId;

    try {
      await api.post(`/api/bff/chat-messages/${messageId}/cancel`, {});
    } catch (error) {
      console.error(error);
      window.alert('Failed to cancel generation.');
      if (params.cancelingGenerationId.value === messageId) params.cancelingGenerationId.value = null;
    }
  };

  const handleCancelPointerDown = (event: PointerEvent) => {
    if (!params.activeGenerationId.value) return;
    event.preventDefault();
  };

  const onPendingFilesSelected = (event: Event) => {
    const input = event.target as HTMLInputElement | null;
    addPendingFiles(Array.from(input?.files || []));
    if (input) input.value = '';
  };

  const addPendingFiles = (files: File[]) => {
    if (params.readOnly.value) return;
    if (!files.length) return;
    addPendingFilesToCollection(pendingFiles, files, params.fileUploadPolicy.value, (error) => {
      params.loadError.value = error;
    });
  };

  const removePendingFile = (id: string) => {
    void removePendingFileFromCollection(pendingFiles, id);
  };

  // A file already uploaded for the message being sent stays as is until the send settles.
  const isPendingFileLockedForSend = (file: PendingChatFile) => sending.value && file.uploadStatus === 'uploaded';

  const setPendingFileOriginal = (id: string, keepOriginal: boolean) => {
    const current = findPendingFile(pendingFiles, id);
    if (!current || isPendingFileLockedForSend(current)) return;
    setPendingFileOriginalInCollection(pendingFiles, id, keepOriginal);
  };

  const syncServerGenerationState = (messageId: number | null | undefined) => {
    const generationId = params.branch.value.some(
      (message) => message.id === messageId && message.status === 'generating'
    ) ? messageId : generatingMessageIdInBranch.value;
    if (generationId) {
      if (params.activeGenerationId.value !== generationId) {
        void startPolling(generationId);
      }
      return;
    }

    if (params.activeGenerationId.value != null) {
      params.activeGenerationId.value = null;
      params.cancelingGenerationId.value = null;
      stopPolling();
    }
  };

  const dispose = async () => {
    draftSync.dispose();
    await clearPendingFilesCollection(pendingFiles);
    stopPolling();
  };

  return {
    pendingFiles,
    activeGenerationId: params.activeGenerationId,
    cancelingGenerationId: params.cancelingGenerationId,
    draft,
    draftStatusLabel,
    draftProblem: draftSync.problem,
    draftSyncState: draftSync.state,
    draftConflict: draftSync.conflict,
    refreshDraft: draftSync.refresh,
    retryDraft: draftSync.flush,
    resolveDraft: draftSync.resolve,
    sending,
    steeringGenerationId,
    generationPollReconnecting,
    hasSendPayload,
    hasFollowUpBacklog,
    canSteerGeneration,
    sendButtonLabel,
    queueButtonLabel,
    cancelButtonLabel,
    steerButtonLabel,
    findPendingFile,
    ensurePendingFilesUploaded,
    addPendingFilesToCollection,
    setPendingFileOriginalInCollection,
    removePendingFileFromCollection,
    clearPendingFilesCollection,
    startPolling,
    stopPolling,
    handleVisibilityChange,
    handlePageShow,
    handleFocus,
    syncServerGenerationState,
    sendMessage,
    queueMessage,
    continueGeneration,
    steerGeneration,
    submitComposer,
    cancelActiveGeneration,
    handleCancelPointerDown,
    onPendingFilesSelected,
    addPendingFiles,
    removePendingFile,
    setPendingFileOriginal,
    dispose,
  };
}
