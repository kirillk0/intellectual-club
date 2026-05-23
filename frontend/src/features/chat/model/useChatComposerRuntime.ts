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
  type PollResponse,
} from '@/features/chat/model/chatViewModel.shared';
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
  scrollToLastMessage: ScrollToLastMessage;
  getOpenWorkingPollRequest?: (messageId: number) => string | null;
  applyWorkingPoll?: (messageId: number, payload: PollResponse['working_open']) => void;
};

export function useChatComposerRuntime(params: Params) {
  const uploadChunkRetryDelaysMs = [500, 1_500];
  const pendingFiles = ref<PendingChatFile[]>([]);
  const draft = ref('');
  const sending = ref(false);

  const sendButtonLabel = computed(() => {
    if (params.activeGenerationId.value) {
      return params.cancelingGenerationId.value === params.activeGenerationId.value ? 'Cancelling…' : 'Cancel';
    }

    if (sending.value) {
      const uploadProgress = overallPendingUploadProgress(pendingFiles.value);
      if (uploadProgress.active) {
        return `Uploading… ${Math.max(1, Math.round(uploadProgress.progress * 100))}%`;
      }

      return 'Sending…';
    }

    return 'Send';
  });

  const errorMessage = (error: unknown, fallback: string) => getApiErrorMessage(error, fallback);

  const waitForAnimationFrame = () =>
    new Promise<void>((resolve) => {
      window.requestAnimationFrame(() => resolve());
    });

  const getPageScroller = () => document.scrollingElement || document.documentElement;

  const getMaxPageScrollTop = () => {
    const scroller = getPageScroller();
    return Math.max(0, scroller.scrollHeight - scroller.clientHeight);
  };

  const isPageScrolledToBottom = () => {
    const scroller = getPageScroller();
    return getMaxPageScrollTop() - scroller.scrollTop <= 8;
  };

  const keepPageScrolledToBottom = async () => {
    await nextTick();
    await waitForAnimationFrame();
    window.scrollTo({ top: getMaxPageScrollTop(), left: window.scrollX, behavior: 'auto' });
    await waitForAnimationFrame();
    window.scrollTo({ top: getMaxPageScrollTop(), left: window.scrollX, behavior: 'auto' });
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

  const ensurePendingFilesUploaded = async (filesRef: Ref<PendingChatFile[]>) => {
    if (!params.chatId.value) return [];

    let index = 0;

    while (index < filesRef.value.length) {
      const item = filesRef.value[index];
      if (!item) break;

      if (item.uploadStatus === 'uploaded' && item.uploadId) {
        index += 1;
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
      if (updated.uploadStatus === 'uploaded' && updated.uploadId) {
        index += 1;
        continue;
      }

      throw new Error(updated.error || 'Failed to upload attachment.');
    }

    return filesRef.value
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

  const stopPolling = () => {
    pollingToken += 1;
    if (pollTimer != null) {
      window.clearTimeout(pollTimer);
      pollTimer = null;
    }
    if (pollAbortController) {
      pollAbortController.abort();
      pollAbortController = null;
    }
  };

  const updateBranchMessage = (messageId: number, patch: Partial<ChatBranchMessage>) => {
    const idx = params.branch.value.findIndex((item) => item.id === messageId);
    if (idx === -1) return;
    params.branch.value[idx] = { ...params.branch.value[idx], ...patch };
  };

  const pollOnce = async (messageId: number, token: number) => {
    const controller = new AbortController();
    pollAbortController = controller;

    const timeoutHandle = window.setTimeout(() => controller.abort(), 25_000);

    try {
      const searchParams = new URLSearchParams();
      const workingStepId = params.getOpenWorkingPollRequest?.(messageId);
      if (workingStepId) searchParams.set('working_step_id', workingStepId);
      const suffix = searchParams.toString() ? `?${searchParams.toString()}` : '';

      const response = await api.get<PollResponse>(`/api/bff/chat-messages/${messageId}/poll${suffix}`, {
        signal: controller.signal,
        showErrorBanner: false,
      });

      if (pollingToken !== token) return false;

      const current = params.branch.value.find((item) => item.id === messageId) || null;
      const shouldKeepPageAtBottom = current ? isPageScrolledToBottom() : false;

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
        if (shouldKeepPageAtBottom) void keepPageScrolledToBottom();
      }

      const doneStatuses = new Set(['done', 'canceled', 'error']);
      if (doneStatuses.has(response.status)) {
        if (params.activeGenerationId.value === messageId) params.activeGenerationId.value = null;
        if (params.cancelingGenerationId.value === messageId) params.cancelingGenerationId.value = null;
        stopPolling();
        return false;
      }

      return true;
    } finally {
      window.clearTimeout(timeoutHandle);
      if (pollAbortController === controller) pollAbortController = null;
    }
  };

  const startPolling = async (messageId: number) => {
    stopPolling();
    params.activeGenerationId.value = messageId;

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

  const send = async () => {
    if (params.readOnly.value) return;
    if (!params.chatId.value || sending.value) return;
    if (params.activeGenerationId.value) return;

    sending.value = true;
    params.loadError.value = '';

    try {
      const configReady = await params.waitForConfigSync();
      if (!configReady) {
        params.loadError.value = 'Configuration change is still syncing. Please wait.';
        return;
      }

      const content = draft.value;
      const hasUserText = content !== '';
      const uploadIds = pendingFiles.value.length > 0 ? await ensurePendingFilesUploaded(pendingFiles) : [];
      const hasPendingFiles = uploadIds.length > 0;

      const payload =
        hasUserText || hasPendingFiles
          ? await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
              `/api/bff/chats/${params.chatId.value}/send`,
              buildSendPayload(content, uploadIds)
            )
          : await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
              `/api/bff/chats/${params.chatId.value}/generate`,
              {}
            );

      params.branch.value = payload.branch || [];
      if (hasUserText) draft.value = '';
      if (hasPendingFiles) pendingFiles.value = [];

      const messageId = payload.generation?.message_id;
      if (messageId) {
        await startPolling(messageId);
      }

      void params.scrollToLastMessage({ behavior: 'smooth', block: 'end' });
    } catch (error) {
      console.error(error);
      params.loadError.value = errorMessage(error, 'Failed to send message.');
    } finally {
      sending.value = false;
    }
  };

  const cancelActiveGeneration = async () => {
    if (params.readOnly.value) return;
    const messageId = params.activeGenerationId.value;
    if (!messageId || params.cancelingGenerationId.value === messageId) return;
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
    sendButtonLabel,
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
    send,
    cancelActiveGeneration,
    handleCancelPointerDown,
    onPendingFilesSelected,
    addPendingFiles,
    removePendingFile,
    dispose,
  };
}
