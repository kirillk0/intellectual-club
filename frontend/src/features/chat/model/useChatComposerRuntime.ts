import { computed, nextTick, ref, watch, type ComputedRef, type Ref } from 'vue';

import { api, getApiErrorMessage, isHttpError } from '@/api/client';
import {
  createPendingChatFiles,
  overallPendingUploadProgress,
  validateFilesForChatUpload,
  type ChatUploadPolicy,
  type PendingChatFile,
} from '@/features/chat/attachments';
import {
  abortChatUploadSession,
  createChatUploadSession,
  getChatUploadSession,
  isRetryableUploadChunkError,
  uploadChatChunk,
  UploadAbortedError,
  type ChatUploadInfo,
} from '@/features/chat/upload';
import {
  buildSendPayload,
  type ChatQueuedMessage,
  type PollResponse,
} from '@/features/chat/model/chatViewModel.shared';
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
  supportsSteering: ComputedRef<boolean>;
  draftReady?: ComputedRef<boolean>;
  autoScrollEnabled?: ComputedRef<boolean>;
  scrollToLastMessage: ScrollToLastMessage;
  getOpenWorkingPollRequest?: (messageId: number) => string | null;
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
    return chatId ? `ic.draft.chat.composer.${chatId}` : null;
  });
  watch(
    () => params.chatId.value,
    () => {
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
    enabled: computed(() => draftReady.value && Boolean(params.chatId.value) && !params.readOnly.value),
    isDraft: computed(() => draft.value !== '' && !params.readOnly.value && Boolean(params.chatId.value)),
    clearValueOnInvalidation: false,
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
    () => Boolean(params.activeGenerationId.value) && params.supportsSteering.value && hasDraftText.value
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
        steering_not_supported: 'Steering is not supported by this configuration.',
        generation_not_active: 'Generation is no longer active.',
        terminal_handoff_in_progress: 'Steering is unavailable during a terminal handoff.',
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

  const resolveChatUpload = async (chatIdValue: number, file: PendingChatFile) => {
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

    return createChatUploadSession(chatIdValue, file.file);
  };

  const resolveWritableChatUpload = async (chatIdValue: number, file: PendingChatFile) => {
    let upload = await resolveChatUpload(chatIdValue, file);
    let offset = Math.min(upload.uploaded_bytes || 0, file.size);

    if (upload.status !== 'uploading' && upload.status !== 'uploaded') {
      upload = await createChatUploadSession(chatIdValue, file.file);
      offset = 0;
    }

    return { upload, offset };
  };

  const waitForUploadRetry = (delayMs: number) =>
    new Promise<void>((resolve) => {
      window.setTimeout(resolve, delayMs);
    });

  const uploadPendingFile = async (
    filesRef: Ref<PendingChatFile[]>,
    fileId: string,
    chatIdValue: number
  ) => {
    const pending = findPendingFile(filesRef, fileId);
    if (!pending) return null;

    let { upload, offset } = await resolveWritableChatUpload(chatIdValue, pending);

    syncPendingFileWithUpload(filesRef, fileId, upload, {
      error: '',
      speedBps: 0,
      etaSeconds: offset >= pending.size ? 0 : null,
    });

    if (upload.status === 'uploaded' || offset >= pending.size) {
      syncPendingFileWithUpload(filesRef, fileId, upload, {
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
      const liveFile = findPendingFile(filesRef, fileId);
      if (!liveFile) return null;

      const chunkSize = Math.min(upload.chunk_size_bytes || liveFile.size, liveFile.size - offset);
      const chunk = liveFile.file.slice(offset, offset + chunkSize);

      try {
        upload = await uploadChatChunk(chatIdValue, upload.upload_id, offset, chunk, {
          onAbortHandle: (abortHandle) => {
            updatePendingFile(filesRef, fileId, { abortHandle });
          },
          onProgress: (loadedBytes) => {
            const currentFile = findPendingFile(filesRef, fileId);
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

        const currentFile = findPendingFile(filesRef, fileId);
        if (!currentFile) return null;

        offset = Math.min(upload.uploaded_bytes || 0, currentFile.size);
        retryAttempt = 0;
        syncPendingFileWithUpload(filesRef, fileId, upload, {
          error: '',
          speedBps: offset >= currentFile.size ? 0 : currentFile.speedBps,
          etaSeconds: offset >= currentFile.size ? 0 : currentFile.etaSeconds,
          abortHandle: null,
        });
      } catch (error) {
        if (error instanceof UploadAbortedError) {
          const stillPresent = findPendingFile(filesRef, fileId);
          if (!stillPresent) return null;

          updatePendingFile(filesRef, fileId, {
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
            const currentFile = findPendingFile(filesRef, fileId);
            if (!currentFile) return null;

            offset = Math.min(nextOffset, currentFile.size);
            resumeOffset = offset;
            startedAt = performance.now();
            retryAttempt = 0;
            upload = await getChatUploadSession(chatIdValue, upload.upload_id);
            syncPendingFileWithUpload(filesRef, fileId, upload, {
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

          updatePendingFile(filesRef, fileId, {
            uploadStatus: 'uploading',
            abortHandle: null,
            speedBps: 0,
            etaSeconds: null,
            error: '',
          });

          await waitForUploadRetry(delayMs);

          const currentFile = findPendingFile(filesRef, fileId);
          if (!currentFile) return null;

          try {
            ({ upload, offset } = await resolveWritableChatUpload(chatIdValue, currentFile));
          } catch (syncError) {
            updatePendingFile(filesRef, fileId, {
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
          syncPendingFileWithUpload(filesRef, fileId, upload, {
            error: '',
            speedBps: 0,
            etaSeconds: offset >= currentFile.size ? 0 : null,
            abortHandle: null,
          });
          continue;
        }

        updatePendingFile(filesRef, fileId, {
          uploadStatus: 'error',
          abortHandle: null,
          speedBps: 0,
          etaSeconds: null,
          error: errorMessage(error, 'Failed to upload attachment.'),
        });

        throw error;
      }
    }

    const finalFile = findPendingFile(filesRef, fileId);
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

  const ensurePendingFilesUploaded = async (
    filesRef: Ref<PendingChatFile[]>,
    fileIds?: ReadonlySet<string>
  ) => {
    if (!params.chatId.value) return [];

    const targetIds = fileIds ? [...fileIds] : filesRef.value.map((item) => item.id);

    for (const fileId of targetIds) {
      const item = findPendingFile(filesRef, fileId);
      if (!item) continue;

      if (item.uploadStatus === 'uploaded' && item.uploadId) {
        continue;
      }

      try {
        await uploadPendingFile(filesRef, item.id, params.chatId.value);
      } catch (error) {
        if (error instanceof UploadAbortedError && !findPendingFile(filesRef, item.id)) {
          continue;
        }

        throw error;
      }

      const updated = findPendingFile(filesRef, item.id);
      if (!updated) continue;
      if (updated.uploadStatus === 'uploaded' && updated.uploadId) continue;

      throw new Error(updated.error || 'Failed to upload attachment.');
    }

    return filesRef.value
      .filter((item) => !fileIds || fileIds.has(item.id))
      .map((item) => item.uploadId)
      .filter((value): value is string => typeof value === 'string' && value.trim() !== '');
  };

  const removePendingFileFromCollection = async (filesRef: Ref<PendingChatFile[]>, id: string) => {
    const current = findPendingFile(filesRef, id);
    if (!current) return;

    current.abortHandle?.();
    filesRef.value = filesRef.value.filter((item) => item.id !== id);

    if (!params.chatId.value || !current.uploadId) return;

    try {
      await abortChatUploadSession(params.chatId.value, current.uploadId);
    } catch (error) {
      if (!isHttpError(error) || error.status !== 404) {
        console.warn('Failed to abort chat upload session', error);
      }
    }
  };

  const clearPendingFilesCollection = async (filesRef: Ref<PendingChatFile[]>) => {
    const snapshot = [...filesRef.value];
    filesRef.value = [];

    for (const item of snapshot) {
      item.abortHandle?.();

      if (!params.chatId.value || !item.uploadId) continue;

      try {
        await abortChatUploadSession(params.chatId.value, item.uploadId);
      } catch (error) {
        if (!isHttpError(error) || error.status !== 404) {
          console.warn('Failed to abort chat upload session', error);
        }
      }
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
  let pollAbortController: AbortController | null = null;
  let lastResumeSyncAt = 0;

  const stopPolling = (opts: { resetConnectionState?: boolean } = {}) => {
    const resetConnectionState = opts.resetConnectionState ?? true;
    pollingToken += 1;
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

    let didTimeout = false;
    const timeoutHandle = window.setTimeout(() => {
      didTimeout = true;
      controller.abort();
    }, 25_000);

    try {
      const searchParams = new URLSearchParams();
      const workingStepId = params.getOpenWorkingPollRequest?.(messageId);
      if (workingStepId) searchParams.set('working_step_id', workingStepId);
      const suffix = searchParams.toString() ? `?${searchParams.toString()}` : '';

      const response = await api.get<PollResponse>(`/api/bff/chat-messages/${messageId}/poll${suffix}`, {
        signal: controller.signal,
        showErrorBanner: false,
        timeoutMs: null,
        retry: false,
      });

      if (pollingToken !== token) return false;
      generationPollReconnecting.value = false;

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

        if (response.content) patch.content = response.content;
        if (response.usage) patch.usage = response.usage;
        if (response.working) patch.working = response.working;

        updateBranchMessage(messageId, patch);
        if (response.working_open !== undefined) {
          params.applyWorkingPoll?.(messageId, response.working_open);
        }
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
        if (params.cancelingGenerationId.value === messageId) params.cancelingGenerationId.value = null;
        stopPolling();
        await params.onGenerationSettled?.(messageId, response.status);
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
    const sameGeneration = params.activeGenerationId.value === messageId;
    stopPolling({ resetConnectionState: !sameGeneration });
    params.activeGenerationId.value = messageId;
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
          pollTimer = window.setTimeout(tick, 500);
        }
      } catch (error) {
        if (pollingToken !== token) return;
        if (error instanceof DOMException && error.name === 'AbortError') return;
        console.warn(error);
        generationPollReconnecting.value = true;
        if (params.activeGenerationId.value === messageId && pollingToken === token) {
          pollTimer = window.setTimeout(tick, 1500);
        }
      }
    };

    await tick();
  };

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
    if (draft.value === content) draft.value = '';
    if (pendingFileIds.size > 0) {
      pendingFiles.value = pendingFiles.value.filter((file) => !pendingFileIds.has(file.id));
    }
    if (draft.value === '') chatTextDraft.clear(storageKey);
  };

  const createQueuedMessage = async (
    content: string,
    uploadIds: string[]
  ) => {
    const payload = await api.post<QueuedMessagePayload>(
      `/api/bff/chat-generation/${params.chatId.value}/queue`,
      buildSendPayload(content, uploadIds)
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

    const draftStorageKeyBeforeSend = chatDraftStorageKey.value;
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

      const hasUserText = content !== '';
      const uploadIds = pendingFileIds.size > 0
        ? await ensurePendingFilesUploaded(pendingFiles, pendingFileIds)
        : [];
      const hasPendingFiles = uploadIds.length > 0;
      if (!hasUserText && !hasPendingFiles) return;

      let payload: GenerationStartPayload;
      try {
        payload = await api.post<GenerationStartPayload>(
          `/api/bff/chat-generation/${params.chatId.value}/send`,
          buildSendPayload(content, uploadIds)
        );
      } catch (error) {
        if (
          isHttpError(error) &&
          error.status === 409 &&
          ['queue_not_empty', 'generation_active'].includes(apiErrorCode(error) || '')
        ) {
          sendingMode.value = 'queue';
          await createQueuedMessage(content, uploadIds);
          clearAcknowledgedComposerSnapshot(content, pendingFileIds, draftStorageKeyBeforeSend);
          return;
        }
        throw error;
      }

      clearAcknowledgedComposerSnapshot(content, pendingFileIds, draftStorageKeyBeforeSend);

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
      sending.value = false;
      sendingMode.value = null;
    }
  };

  const queueMessage = async () => {
    if (params.readOnly.value || !params.chatId.value || sending.value || !hasSendPayload.value) return;

    const content = draft.value;
    const pendingFileIds = new Set(pendingFiles.value.map((file) => file.id));
    const draftStorageKeyBeforeQueue = chatDraftStorageKey.value;
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

      await createQueuedMessage(content, uploadIds);
      clearAcknowledgedComposerSnapshot(content, pendingFileIds, draftStorageKeyBeforeQueue);
    } catch (error) {
      console.error(error);
      params.loadError.value = queueErrorMessage(error);
    } finally {
      sending.value = false;
      sendingMode.value = null;
    }
  };

  const continueGeneration = async () => {
    if (params.readOnly.value) return;
    if (!params.chatId.value || sending.value) return;
    if (params.activeGenerationId.value || hasSendPayload.value) return;

    sending.value = true;
    sendingMode.value = 'continue';
    params.loadError.value = '';

    try {
      const configReady = await params.waitForConfigSync();
      if (!configReady) {
        params.loadError.value = translate('Configuration change is still syncing. Please wait.');
        return;
      }

      const payload = await api.post<GenerationStartPayload>(
        `/api/bff/chat-generation/${params.chatId.value}/generate`,
        {}
      );
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
    steeringGenerationId.value = messageId;
    params.loadError.value = '';

    try {
      const payload = await api.post<QueuedMessagePayload>(
        `/api/bff/chat-messages/${messageId}/steer`,
        { content }
      );

      if (payload.queued_message) params.onQueuedMessageCreated?.(payload.queued_message);

      if (draft.value === content) {
        draft.value = '';
        chatTextDraft.clear(draftStorageKeyBeforeSteer);
      }

      if (params.activeGenerationId.value === messageId) {
        void startPolling(messageId);
      }
    } catch (error) {
      console.error(error);
      params.loadError.value = steeringErrorMessage(error);
    } finally {
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
    const { accepted, errors } = validateFilesForChatUpload(files, params.fileUploadPolicy.value);

    if (accepted.length > 0) {
      pendingFiles.value = [...pendingFiles.value, ...createPendingChatFiles(accepted)];
    }

    params.loadError.value = errors[0] || '';
  };

  const removePendingFile = (id: string) => {
    void removePendingFileFromCollection(pendingFiles, id);
  };

  const syncServerGenerationState = (messageId: number | null | undefined) => {
    const generationId = messageId || null;
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
    await clearPendingFilesCollection(pendingFiles);
    stopPolling();
  };

  return {
    pendingFiles,
    activeGenerationId: params.activeGenerationId,
    cancelingGenerationId: params.cancelingGenerationId,
    draft,
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
    dispose,
  };
}
