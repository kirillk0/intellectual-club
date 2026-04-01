import { computed, ref, type ComputedRef, type Ref } from 'vue';

import { api, getApiErrorMessage } from '@/api/client';
import {
  createPendingChatFiles,
  mapContentToExistingAttachment,
  overallPendingUploadProgress,
  validateFilesForChatUpload,
  type ChatUploadPolicy,
  type ExistingChatAttachment,
  type PendingChatFile,
} from '@/features/chat/attachments';
import {
  buildMessageUpdatePayload,
  buildSendPayload,
} from '@/features/chat/model/chatViewModel.shared';
import { copyTextWithFallback } from '@/utils/clipboard';
import type { Chat, ChatBranchMessage } from '@/types/api';

type ScrollToLastMessage = (opts?: {
  behavior?: ScrollBehavior;
  block?: ScrollLogicalPosition;
}) => Promise<void> | void;

type Params = {
  chatId: ComputedRef<number>;
  chat: Ref<Chat | null>;
  branch: Ref<ChatBranchMessage[]>;
  selectedConfig: Ref<number | ''>;
  fileUploadPolicy: ComputedRef<ChatUploadPolicy>;
  isConfigSyncPending: ComputedRef<boolean>;
  messageConfigLabel: (configId?: number | null) => string;
  startPolling: (messageId: number) => Promise<void>;
  scrollToLastMessage: ScrollToLastMessage;
  ensurePendingFilesUploaded: (filesRef: Ref<PendingChatFile[]>) => Promise<string[]>;
  removePendingFileFromCollection: (filesRef: Ref<PendingChatFile[]>, id: string) => Promise<void>;
  clearPendingFilesCollection: (filesRef: Ref<PendingChatFile[]>) => Promise<void>;
  afterBranchSwitched?: () => void;
};

export function useChatMessageActions(params: Params) {
  const copiedMessageId = ref<number | null>(null);
  const retryingMessageId = ref<number | null>(null);
  const branchingAssistantId = ref<number | null>(null);
  const deletingMessageId = ref<number | null>(null);
  const workingOpenById = ref<Set<number>>(new Set());

  const editingMessage = ref<ChatBranchMessage | null>(null);
  const modalMode = ref<'edit' | 'branch'>('edit');
  const editContentIds = ref<number[]>([]);
  const editContents = ref<string[]>([]);
  const editExistingAttachments = ref<ExistingChatAttachment[]>([]);
  const editRemovedAttachmentIds = ref<number[]>([]);
  const editPendingFiles = ref<PendingChatFile[]>([]);
  const editError = ref('');
  const savingEdit = ref(false);

  const editSaveLabel = computed(() => {
    if (!savingEdit.value) return modalMode.value === 'branch' ? 'Branch' : 'Save';

    const uploadProgress = overallPendingUploadProgress(editPendingFiles.value);
    if (uploadProgress.active) {
      return `Uploading… ${Math.max(1, Math.round(uploadProgress.progress * 100))}%`;
    }

    return modalMode.value === 'branch' ? 'Branching…' : 'Saving…';
  });

  const errorMessage = (error: unknown, fallback: string) => getApiErrorMessage(error, fallback);
  const confirm = (message: string) => window.confirm(message);
  const alert = (message: string) => window.alert(message);

  const joinTextContents = (contents: unknown) => {
    const list = Array.isArray(contents) ? contents : [];
    return list
      .filter((content) => content && typeof content === 'object' && (content as { kind?: unknown }).kind === 'text')
      .map((content) => String((content as { content_text?: unknown }).content_text ?? ''))
      .join('');
  };

  const messagePrimaryText = (msg: ChatBranchMessage) => {
    const wantedType = msg.role === 'user' ? 'input' : 'answer';
    const steps = msg.steps || [];
    const items = steps.flatMap((step) => step.items || []);
    return items
      .filter((item) => item && item.type === wantedType)
      .map((item) => joinTextContents(item.contents))
      .filter((text) => String(text).trim() !== '')
      .join('\n\n');
  };

  const copyMessage = async (msg: ChatBranchMessage) => {
    try {
      const copied = await copyTextWithFallback(messagePrimaryText(msg), {
        promptLabel: 'Copy the message text manually:',
      });
      if (!copied) return;
      copiedMessageId.value = msg.id;
      window.setTimeout(() => {
        if (copiedMessageId.value === msg.id) copiedMessageId.value = null;
      }, 1200);
    } catch (error) {
      console.warn(error);
    }
  };

  const branchMessageById = (messageId: number | null | undefined) => {
    if (!messageId) return null;
    return params.branch.value.find((item) => item.id === messageId) || null;
  };

  const currentRetryConfigurationId = () => {
    const configId = params.selectedConfig.value || params.chat.value?.llm_configuration_id || null;
    return typeof configId === 'number' && Number.isFinite(configId) && configId > 0 ? configId : null;
  };

  const retryConfigurationWarning = (message: ChatBranchMessage | null | undefined) => {
    if (!message || message.role !== 'assistant') return '';

    const messageConfigId =
      typeof message.llm_configuration_id === 'number' &&
      Number.isFinite(message.llm_configuration_id) &&
      message.llm_configuration_id > 0
        ? message.llm_configuration_id
        : null;
    const currentConfigId = currentRetryConfigurationId();

    if (!messageConfigId || !currentConfigId || messageConfigId === currentConfigId) return '';

    const originalLabel = params.messageConfigLabel(messageConfigId);
    const selectedLabel = params.messageConfigLabel(currentConfigId);

    return `Warning: this retry will use the original message configuration (${originalLabel}), not the currently selected chat configuration (${selectedLabel}).`;
  };

  const canDeleteMessage = (msg: ChatBranchMessage, _idx: number) => {
    if (!msg.id) return false;
    if (msg.status === 'generating') return false;
    if (deletingMessageId.value === msg.id) return false;
    return true;
  };

  const deleteMessageTitle = (msg: ChatBranchMessage, _idx: number) => {
    if (!msg.id) return 'Message is not saved yet';
    if (msg.status === 'generating') return 'Cannot delete while generating';
    if (deletingMessageId.value === msg.id) return 'Deleting…';
    return 'Delete';
  };

  const confirmAndDeleteMessage = async (msg: ChatBranchMessage, idx: number) => {
    if (!msg.id) return;
    if (!canDeleteMessage(msg, idx)) {
      alert(deleteMessageTitle(msg, idx));
      return;
    }

    if (!confirm('Delete this message?')) return;

    deletingMessageId.value = msg.id;
    try {
      const payload = await api.post<{ branch: ChatBranchMessage[] }>(
        `/api/bff/chat-messages/${msg.id}/delete`,
        {}
      );
      params.branch.value = payload.branch || [];
    } catch (error) {
      console.error(error);
      alert('Failed to delete the message.');
    } finally {
      if (deletingMessageId.value === msg.id) deletingMessageId.value = null;
    }
  };

  const isWorkingOpen = (id: number | null | undefined) => {
    if (!id) return false;
    return workingOpenById.value.has(id);
  };

  const toggleWorking = (id: number | null | undefined) => {
    if (!id) return;
    const next = new Set(workingOpenById.value);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    workingOpenById.value = next;
  };

  const retryLastStep = async (msg: ChatBranchMessage) => {
    const messageId = msg.id;
    if (!params.chatId.value || !messageId) return;
    if (retryingMessageId.value === messageId) return;

    const retryWarning = retryConfigurationWarning(msg);
    if (retryWarning && !confirm(`${retryWarning}\n\nRetry anyway?`)) return;

    retryingMessageId.value = messageId;

    try {
      const payload = await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
        `/api/bff/chat-messages/${messageId}/retry-last-step`,
        {}
      );

      params.branch.value = payload.branch || [];

      const generationId = payload.generation?.message_id;
      if (generationId) {
        await params.startPolling(generationId);
      }

      void params.scrollToLastMessage({ behavior: 'smooth', block: 'end' });
    } catch (error) {
      console.error(error);
      alert('Failed to retry the last step.');
    } finally {
      if (retryingMessageId.value === messageId) retryingMessageId.value = null;
    }
  };

  const switchBranchHandler = async (
    messageId: number,
    direction?: 'prev' | 'next',
    targetId?: number
  ) => {
    if (!params.chatId.value) return;
    try {
      const payload = await api.post<{ branch: ChatBranchMessage[] }>(
        `/api/bff/chats/${params.chatId.value}/switch-branch`,
        {
          message_id: messageId,
          direction,
          target_id: targetId,
        }
      );
      params.branch.value = payload.branch || [];
      params.afterBranchSwitched?.();
    } catch (error) {
      console.error(error);
    }
  };

  const extractEditableTextContents = (msg: ChatBranchMessage) => {
    const wantedType = msg.role === 'user' ? 'input' : 'answer';
    const targets: Array<{ id: number; sequence: number; text: string }> = [];

    const steps = msg.steps || [];
    for (const step of [...steps].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0))) {
      const items = step.items || [];
      for (const item of [...items].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0))) {
        if (item.type !== wantedType) continue;

        const contents = item.contents || [];
        for (const content of [...contents].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0))) {
          if (content.kind !== 'text') continue;
          if (typeof content.id !== 'number') continue;
          targets.push({
            id: content.id,
            sequence: content.sequence ?? 0,
            text: String(content.content_text ?? ''),
          });
        }
      }
    }

    return targets;
  };

  const extractEditableMediaContents = (msg: ChatBranchMessage) => {
    if (!msg.id) return [];

    const wantedType = msg.role === 'user' ? 'input' : 'artifact';
    const attachments: ExistingChatAttachment[] = [];

    const steps = msg.steps || [];
    for (const step of [...steps].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0))) {
      const items = step.items || [];
      for (const item of [...items].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0))) {
        if (item.type !== wantedType) continue;

        const contents = item.contents || [];
        for (const content of [...contents].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0))) {
          const attachment = mapContentToExistingAttachment(content, msg.id);
          if (attachment) attachments.push(attachment);
        }
      }
    }

    return attachments;
  };

  const startEdit = (msg: ChatBranchMessage) => {
    if (!msg.id) return;
    void params.clearPendingFilesCollection(editPendingFiles);
    const targets = extractEditableTextContents(msg);
    const attachments = extractEditableMediaContents(msg);

    if (targets.length === 0 && attachments.length === 0) {
      alert('No editable text content found for this message.');
      return;
    }

    editingMessage.value = msg;
    modalMode.value = 'edit';
    editContentIds.value = targets.map((target) => target.id);
    editContents.value = targets.map((target) => target.text);
    editExistingAttachments.value = attachments;
    editRemovedAttachmentIds.value = [];
    editPendingFiles.value = [];
    editError.value = '';
  };

  const branchFromAssistant = async (msg: ChatBranchMessage) => {
    if (!msg.id || !params.chatId.value) return;
    if (branchingAssistantId.value === msg.id) return;
    if (params.isConfigSyncPending.value) {
      alert('Configuration change is still syncing. Please wait before starting a new generation.');
      return;
    }

    const parentId = msg.parent_id ?? null;
    if (!parentId) {
      alert('Cannot branch: missing parent message.');
      return;
    }

    branchingAssistantId.value = msg.id;
    try {
      const payload = await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
        `/api/bff/chats/${params.chatId.value}/generate`,
        { parent_id: parentId }
      );
      params.branch.value = payload.branch || [];
      const messageId = payload.generation?.message_id;
      if (messageId) {
        await params.startPolling(messageId);
      }
    } catch (error) {
      console.error(error);
      alert('Failed to branch from assistant message.');
    } finally {
      branchingAssistantId.value = null;
    }
  };

  const startBranch = (msg: ChatBranchMessage) => {
    if (!msg.id) return;
    if (msg.role === 'user') {
      void params.clearPendingFilesCollection(editPendingFiles);
      const attachments = extractEditableMediaContents(msg);
      editingMessage.value = msg;
      modalMode.value = 'branch';
      editContentIds.value = [];
      editContents.value = [messagePrimaryText(msg)];
      editExistingAttachments.value = attachments;
      editRemovedAttachmentIds.value = [];
      editPendingFiles.value = [];
      editError.value = '';
      return;
    }

    void branchFromAssistant(msg);
  };

  const resetEditState = () => {
    editingMessage.value = null;
    editContentIds.value = [];
    editContents.value = [];
    editExistingAttachments.value = [];
    editRemovedAttachmentIds.value = [];
    editPendingFiles.value = [];
    editError.value = '';
  };

  const cancelEdit = () => {
    void params.clearPendingFilesCollection(editPendingFiles);
    resetEditState();
  };

  const removeEditExistingAttachment = (contentId: number) => {
    editRemovedAttachmentIds.value = [...new Set([...editRemovedAttachmentIds.value, contentId])];
    editExistingAttachments.value = editExistingAttachments.value.filter((item) => item.id !== contentId);
  };

  const addEditPendingFiles = (files: File[]) => {
    if (!files.length) return;
    const { accepted, errors } = validateFilesForChatUpload(files, params.fileUploadPolicy.value);

    if (accepted.length > 0) {
      editPendingFiles.value = [...editPendingFiles.value, ...createPendingChatFiles(accepted)];
    }

    editError.value = errors[0] || '';
  };

  const removeEditPendingFile = (id: string) => {
    void params.removePendingFileFromCollection(editPendingFiles, id);
  };

  const saveEdit = async () => {
    if (!editingMessage.value?.id || savingEdit.value) return;
    savingEdit.value = true;
    editError.value = '';

    try {
      if (modalMode.value === 'edit') {
        const updates = editContentIds.value.map((id, idx) => ({
          id,
          content_text: editContents.value[idx] ?? '',
        }));

        const hasTextUpdates = updates.length > 0;
        const uploadIds =
          editPendingFiles.value.length > 0 ? await params.ensurePendingFilesUploaded(editPendingFiles) : [];

        const updatePayload = buildMessageUpdatePayload(
          hasTextUpdates ? updates : null,
          editRemovedAttachmentIds.value,
          uploadIds
        );

        const payload = await api.patch<{ branch: ChatBranchMessage[] }>(
          `/api/bff/chat-messages/${editingMessage.value.id}`,
          updatePayload
        );
        params.branch.value = payload.branch || [];
        resetEditState();
      } else {
        if (params.isConfigSyncPending.value) {
          alert('Configuration change is still syncing. Please wait before starting a new generation.');
          return;
        }

        const parentId = editingMessage.value.parent_id ?? null;
        const uploadIds =
          editPendingFiles.value.length > 0 ? await params.ensurePendingFilesUploaded(editPendingFiles) : [];
        const hasBranchFiles = editExistingAttachments.value.length > 0 || uploadIds.length > 0;

        const payload = await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
          `/api/bff/chats/${params.chatId.value}/send`,
          hasBranchFiles
            ? buildSendPayload(
                editContents.value[0] ?? '',
                uploadIds,
                editExistingAttachments.value,
                parentId
              )
            : { content: editContents.value[0] ?? '', parent_id: parentId }
        );
        params.branch.value = payload.branch || [];
        resetEditState();

        const messageId = payload.generation?.message_id;
        if (messageId) {
          await params.startPolling(messageId);
        }
      }
    } catch (error) {
      console.error(error);
      editError.value =
        modalMode.value === 'edit'
          ? errorMessage(error, 'Failed to save the message.')
          : errorMessage(error, 'Failed to branch.');
      alert(editError.value);
    } finally {
      savingEdit.value = false;
    }
  };

  const dispose = async () => {
    await params.clearPendingFilesCollection(editPendingFiles);
  };

  return {
    copiedMessageId,
    retryingMessageId,
    branchingAssistantId,
    editingMessage,
    modalMode,
    editContents,
    editExistingAttachments,
    editPendingFiles,
    editError,
    savingEdit,
    editSaveLabel,
    messagePrimaryText,
    copyMessage,
    branchMessageById,
    retryConfigurationWarning,
    canDeleteMessage,
    deleteMessageTitle,
    confirmAndDeleteMessage,
    isWorkingOpen,
    toggleWorking,
    retryLastStep,
    switchBranchHandler,
    startEdit,
    startBranch,
    cancelEdit,
    removeEditExistingAttachment,
    addEditPendingFiles,
    removeEditPendingFile,
    saveEdit,
    dispose,
  };
}
