import { computed, ref, type ComputedRef, type Ref } from 'vue';

import { api, getApiErrorMessage, isHttpError } from '@/api/client';
import {
  createPendingChatFiles,
  validateFilesForChatUpload,
  type ChatUploadPolicy,
  type ExistingChatAttachment,
  type PendingChatFile,
} from '@/features/chat/attachments';
import type {
  ChatQueuedMessage,
  ChatQueuedMessageContent,
  ChatQueuedMessageFile,
} from '@/features/chat/model/chatViewModel.shared';
import { translate } from '@/i18n';

type Params = {
  chatId: ComputedRef<number>;
  queuedMessages: Ref<ChatQueuedMessage[]>;
  readOnly: ComputedRef<boolean>;
  loadError: Ref<string>;
  fileUploadPolicy: ComputedRef<ChatUploadPolicy>;
  ensurePendingFilesUploaded: (
    files: Ref<PendingChatFile[]>,
    fileIds?: ReadonlySet<string>
  ) => Promise<string[]>;
  removePendingFileFromCollection: (files: Ref<PendingChatFile[]>, id: string) => Promise<void>;
  clearPendingFilesCollection: (files: Ref<PendingChatFile[]>) => Promise<void>;
  refreshChat: () => Promise<void>;
};

type QueuedMessageMutationPayload = {
  queued_message: ChatQueuedMessage;
};

const editableStatuses = new Set(['pending', 'blocked']);
const visibleStatuses = new Set(['pending', 'blocked']);

export const isVisibleQueuedMessage = (message: ChatQueuedMessage) =>
  visibleStatuses.has(message.status);

export const isEditableQueuedMessage = (message: ChatQueuedMessage) =>
  editableStatuses.has(message.status);

type NormalizedQueuedContent = {
  id: number;
  position: number;
  type: 'text' | 'media';
  text: string;
  file: ChatQueuedMessageFile | null;
};

export const normalizeQueuedMessageContents = (
  message: ChatQueuedMessage
): NormalizedQueuedContent[] =>
  [...(message.contents || message.content || [])]
    .map((content: ChatQueuedMessageContent) => {
      const type = content.type || content.kind;
      return {
        id: content.id,
        position: content.position ?? content.sequence ?? 0,
        type: type === 'media' ? 'media' as const : 'text' as const,
        text: String(content.text ?? content.content_text ?? ''),
        file: content.file || null,
      };
    })
    .sort((left, right) => left.position - right.position || left.id - right.id);

export const queuedMessageText = (message: ChatQueuedMessage) =>
  normalizeQueuedMessageContents(message)
    .filter((content) => content.type === 'text')
    .map((content) => content.text)
    .join('\n');

export const queuedMessageAttachments = (message: ChatQueuedMessage): ExistingChatAttachment[] =>
  normalizeQueuedMessageContents(message)
    .filter((content): content is NormalizedQueuedContent & { file: ChatQueuedMessageFile } =>
      content.type === 'media' && content.file != null
    )
    .map((content) => ({
      id: content.id,
      messageId: message.id,
      queuedMessageId: message.id,
      name: content.file.filename,
      size: content.file.size ?? content.file.size_bytes ?? 0,
      mimeType: content.file.content_type || content.file.mime_type || 'application/octet-stream',
      isImage: (content.file.content_type || content.file.mime_type || '').toLowerCase().startsWith('image/'),
      content: {
        id: content.id,
        sequence: content.position,
        kind: 'media',
        media: {
          external_id: content.file.external_id || String(content.file.id),
          filename: content.file.filename,
          mime_type: content.file.content_type || content.file.mime_type || 'application/octet-stream',
          size_bytes: content.file.size ?? content.file.size_bytes ?? 0,
          sha256: '',
          is_image: (content.file.content_type || content.file.mime_type || '').toLowerCase().startsWith('image/'),
        },
      },
    }));

export function useChatQueueRuntime(params: Params) {
  const queueActionId = ref<number | null>(null);
  const editingQueuedMessage = ref<ChatQueuedMessage | null>(null);
  const editContents = ref<string[]>([]);
  const editExistingAttachments = ref<ExistingChatAttachment[]>([]);
  const editPendingFiles = ref<PendingChatFile[]>([]);
  const editRemovedAttachmentIds = ref<number[]>([]);
  const editError = ref('');
  const savingEdit = ref(false);

  const visibleQueuedMessages = computed(() =>
    params.queuedMessages.value.filter(isVisibleQueuedMessage)
  );
  const followUpMessages = computed(() =>
    visibleQueuedMessages.value.filter((message) => message.kind === 'follow_up')
  );
  const hasFollowUpBacklog = computed(() => followUpMessages.value.length > 0);
  const headFollowUpId = computed(() => followUpMessages.value[0]?.id ?? null);

  const upsertQueuedMessage = (message: ChatQueuedMessage) => {
    if (!isVisibleQueuedMessage(message)) {
      params.queuedMessages.value = params.queuedMessages.value.filter((item) => item.id !== message.id);
      return;
    }

    const index = params.queuedMessages.value.findIndex((item) => item.id === message.id);
    if (index === -1) {
      params.queuedMessages.value = [...params.queuedMessages.value, message];
      return;
    }

    params.queuedMessages.value = params.queuedMessages.value.map((item) =>
      item.id === message.id ? message : item
    );
  };

  const resetEditState = () => {
    editingQueuedMessage.value = null;
    editContents.value = [];
    editExistingAttachments.value = [];
    editPendingFiles.value = [];
    editRemovedAttachmentIds.value = [];
    editError.value = '';
    savingEdit.value = false;
  };

  const cancelEdit = async () => {
    if (savingEdit.value) return;
    await params.clearPendingFilesCollection(editPendingFiles);
    resetEditState();
  };

  const startEdit = (message: ChatQueuedMessage) => {
    if (params.readOnly.value || !isEditableQueuedMessage(message)) return;
    editingQueuedMessage.value = message;
    editContents.value = [queuedMessageText(message)];
    editExistingAttachments.value = queuedMessageAttachments(message);
    editPendingFiles.value = [];
    editRemovedAttachmentIds.value = [];
    editError.value = '';
  };

  const addEditPendingFiles = (files: File[]) => {
    if (params.readOnly.value || editingQueuedMessage.value?.kind !== 'follow_up') return;
    const { accepted, errors } = validateFilesForChatUpload(files, params.fileUploadPolicy.value);
    if (accepted.length > 0) {
      editPendingFiles.value = [...editPendingFiles.value, ...createPendingChatFiles(accepted)];
    }
    editError.value = errors[0] || '';
  };

  const removeEditPendingFile = (id: string) => {
    void params.removePendingFileFromCollection(editPendingFiles, id);
  };

  const removeEditExistingAttachment = (contentId: number) => {
    if (!editingQueuedMessage.value || savingEdit.value) return;
    if (!editRemovedAttachmentIds.value.includes(contentId)) {
      editRemovedAttachmentIds.value = [...editRemovedAttachmentIds.value, contentId];
    }
    editExistingAttachments.value = editExistingAttachments.value.filter(
      (attachment) => attachment.id !== contentId
    );
  };

  const mutationError = (error: unknown, fallback: string) => {
    if (isHttpError(error) && error.bodyJson && typeof error.bodyJson === 'object') {
      const code = (error.bodyJson as { code?: unknown }).code;
      const messageByCode: Record<string, string> = {
        already_dispatched: 'This queued message has already been dispatched.',
        not_queue_head: 'Only the first queued follow-up can be sent next.',
        not_head: 'Only the first queued follow-up can be sent next.',
        generation_active: 'Wait for the active generation to stop before sending the next queued message.',
        generation_in_progress: 'Wait for the active generation to stop before sending the next queued message.',
        branch_changed: 'The active branch changed. Use Send next to continue on this branch.',
        empty_message: 'A queued message must contain text or an attachment.',
        invalid_file_ids: 'Some queued attachments are no longer available.',
        invalid_remove_content_ids: 'Some queued attachments cannot be edited.',
        follow_up_required: 'Only follow-up messages can be sent next.',
      };
      if (typeof code === 'string' && messageByCode[code]) return translate(messageByCode[code]);
    }

    return getApiErrorMessage(error, translate(fallback));
  };

  const saveEdit = async () => {
    const message = editingQueuedMessage.value;
    if (!message || params.readOnly.value || savingEdit.value || !isEditableQueuedMessage(message)) return;

    const content = editContents.value[0] ?? '';
    const pendingIds = new Set(editPendingFiles.value.map((file) => file.id));
    if (
      content === '' &&
      message.kind === 'steer'
    ) {
      editError.value = translate('Steering content must not be empty.');
      return;
    }
    if (
      content === '' &&
      message.kind === 'follow_up' &&
      editExistingAttachments.value.length === 0 &&
      pendingIds.size === 0
    ) {
      editError.value = translate('A queued message must contain text or an attachment.');
      return;
    }

    savingEdit.value = true;
    editError.value = '';

    try {
      const uploadIds = pendingIds.size > 0
        ? await params.ensurePendingFilesUploaded(editPendingFiles, pendingIds)
        : [];
      const payload = await api.patch<QueuedMessageMutationPayload>(
        `/api/bff/chat-queued-messages/${message.id}`,
        {
          content,
          ...(uploadIds.length > 0 ? { upload_ids: uploadIds } : {}),
          ...(editRemovedAttachmentIds.value.length > 0
            ? { remove_content_ids: editRemovedAttachmentIds.value }
            : {}),
        }
      );

      upsertQueuedMessage(payload.queued_message);
      editPendingFiles.value = editPendingFiles.value.filter((file) => !pendingIds.has(file.id));
      await params.clearPendingFilesCollection(editPendingFiles);
      resetEditState();
    } catch (error) {
      console.error(error);
      editError.value = mutationError(error, 'Failed to update queued message.');
      if (isHttpError(error) && error.status === 409) {
        await params.refreshChat();
        if (error.bodyJson && typeof error.bodyJson === 'object') {
          const code = (error.bodyJson as { code?: unknown }).code;
          if (code === 'already_dispatched') {
            params.loadError.value = editError.value;
            await params.clearPendingFilesCollection(editPendingFiles);
            resetEditState();
          }
        }
      }
    } finally {
      savingEdit.value = false;
    }
  };

  const removeFromQueue = async (message: ChatQueuedMessage) => {
    if (params.readOnly.value || queueActionId.value || !isEditableQueuedMessage(message)) return;
    if (!window.confirm(translate('Remove this message from the queue?'))) return;

    queueActionId.value = message.id;
    params.loadError.value = '';
    try {
      const payload = await api.del<QueuedMessageMutationPayload>(
        `/api/bff/chat-queued-messages/${message.id}`
      );
      upsertQueuedMessage(payload.queued_message);
    } catch (error) {
      console.error(error);
      params.loadError.value = mutationError(error, 'Failed to remove queued message.');
      if (isHttpError(error) && error.status === 409) await params.refreshChat();
    } finally {
      queueActionId.value = null;
    }
  };

  const sendNext = async (message: ChatQueuedMessage) => {
    if (
      params.readOnly.value ||
      queueActionId.value ||
      message.kind !== 'follow_up' ||
      message.id !== headFollowUpId.value
    ) return;

    queueActionId.value = message.id;
    params.loadError.value = '';
    try {
      const payload = await api.post<QueuedMessageMutationPayload>(
        `/api/bff/chat-queued-messages/${message.id}/send-next`,
        {}
      );
      upsertQueuedMessage(payload.queued_message);
      await params.refreshChat();
    } catch (error) {
      console.error(error);
      params.loadError.value = mutationError(error, 'Failed to send the next queued message.');
      if (isHttpError(error) && error.status === 409) await params.refreshChat();
    } finally {
      queueActionId.value = null;
    }
  };

  const dispose = async () => {
    await params.clearPendingFilesCollection(editPendingFiles);
    resetEditState();
  };

  return {
    visibleQueuedMessages,
    followUpMessages,
    hasFollowUpBacklog,
    headFollowUpId,
    queueActionId,
    editingQueuedMessage,
    editContents,
    editExistingAttachments,
    editPendingFiles,
    editError,
    savingEdit,
    startEdit,
    cancelEdit,
    addEditPendingFiles,
    removeEditPendingFile,
    removeEditExistingAttachment,
    saveEdit,
    removeFromQueue,
    sendNext,
    dispose,
  };
}
