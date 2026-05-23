import { computed, ref, watch, type ComputedRef, type Ref } from 'vue';

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
  type PollResponse,
  type WorkingPayload,
} from '@/features/chat/model/chatViewModel.shared';
import { copyTextWithFallback } from '@/utils/clipboard';
import type { Chat, ChatBranchMessage, ChatMessageStep } from '@/types/api';

type ScrollToLastMessage = (opts?: {
  behavior?: ScrollBehavior;
  block?: ScrollLogicalPosition;
}) => Promise<void> | void;

type Params = {
  chatId: ComputedRef<number>;
  chat: Ref<Chat | null>;
  readOnly: ComputedRef<boolean>;
  branch: Ref<ChatBranchMessage[]>;
  selectedConfig: Ref<number | ''>;
  fileUploadPolicy: ComputedRef<ChatUploadPolicy>;
  waitForConfigSync: (timeoutMs?: number) => Promise<boolean>;
  messageConfigLabel: (configId?: number | null) => string;
  startPolling: (messageId: number) => Promise<void>;
  scrollToLastMessage: ScrollToLastMessage;
  ensurePendingFilesUploaded: (filesRef: Ref<PendingChatFile[]>) => Promise<string[]>;
  removePendingFileFromCollection: (filesRef: Ref<PendingChatFile[]>, id: string) => Promise<void>;
  clearPendingFilesCollection: (filesRef: Ref<PendingChatFile[]>) => Promise<void>;
  afterBranchSwitched?: () => void;
};

export type OpenWorkingState = {
  messageId: number;
  steps: ChatMessageStep[];
  selectedStepId: number | null;
  selectedStep: ChatMessageStep | null;
  selectedLatest: boolean;
  open: boolean;
  loading: boolean;
  error: string;
};

export function useChatMessageActions(params: Params) {
  const copiedMessageId = ref<number | null>(null);
  const retryingMessageId = ref<number | null>(null);
  const branchingAssistantId = ref<number | null>(null);
  const deletingMessageId = ref<number | null>(null);
  const bookmarkingMessageIds = ref<Set<number>>(new Set());
  const openWorking = ref<OpenWorkingState | null>(null);
  let workingLoadVersion = 0;

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

  const messagePrimaryText = (msg: ChatBranchMessage) => {
    const texts = (msg.content?.parts || [])
      .map((part) => String(part.text ?? ''))
      .filter((text) => String(text).trim() !== '');
    return texts.at(-1) ?? '';
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

  const updateBranchMessage = (messageId: number, patch: Partial<ChatBranchMessage>) => {
    const idx = params.branch.value.findIndex((item) => item.id === messageId);
    if (idx === -1) return;
    params.branch.value[idx] = { ...params.branch.value[idx], ...patch };
  };

  const clearWorking = () => {
    workingLoadVersion += 1;
    openWorking.value = null;
  };

  const closeWorking = () => {
    const current = openWorking.value;
    if (!current) return;
    workingLoadVersion += 1;
    openWorking.value = { ...current, open: false, loading: false, error: '' };
  };

  const replaceBranch = (nextBranch: ChatBranchMessage[] | null | undefined) => {
    params.branch.value = nextBranch || [];
    clearWorking();
  };

  const isLatestStepId = (steps: ChatMessageStep[], selectedStepId: number | null | undefined) => {
    if (!selectedStepId || !steps.length) return true;
    const latest = [...steps].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0)).at(-1);
    return latest?.id === selectedStepId;
  };

  const isBookmarkingMessage = (messageId: number | null | undefined) => {
    if (!messageId) return false;
    return bookmarkingMessageIds.value.has(messageId);
  };

  const toggleBookmark = async (msg: ChatBranchMessage) => {
    if (params.readOnly.value) return;
    const messageId = msg.id;
    if (!messageId) return;
    if (isBookmarkingMessage(messageId)) return;

    const nextPending = new Set(bookmarkingMessageIds.value);
    nextPending.add(messageId);
    bookmarkingMessageIds.value = nextPending;

    try {
      const payload = await api.post<{ message_id: number; bookmarked: boolean }>(
        `/api/bff/chat-messages/${messageId}/bookmark`,
        {}
      );
      updateBranchMessage(messageId, { bookmarked: Boolean(payload.bookmarked) });
    } catch (error) {
      console.error(error);
      alert(errorMessage(error, 'Failed to toggle bookmark.'));
    } finally {
      const next = new Set(bookmarkingMessageIds.value);
      next.delete(messageId);
      bookmarkingMessageIds.value = next;
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
    if (params.readOnly.value) return false;
    if (!msg.id) return false;
    if (msg.status === 'generating') return false;
    if (deletingMessageId.value === msg.id) return false;
    return true;
  };

  const deleteMessageTitle = (msg: ChatBranchMessage, _idx: number) => {
    if (params.readOnly.value) return 'Shared chats are read-only';
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
      replaceBranch(payload.branch);
    } catch (error) {
      console.error(error);
      alert('Failed to delete the message.');
    } finally {
      if (deletingMessageId.value === msg.id) deletingMessageId.value = null;
    }
  };

  const isWorkingOpen = (id: number | null | undefined) => {
    if (!id) return false;
    return openWorking.value?.messageId === id && openWorking.value.open;
  };

  const workingStateFor = (id: number | null | undefined) => {
    if (!id) return null;
    return openWorking.value?.messageId === id ? openWorking.value : null;
  };

  const loadWorking = async (messageId: number, stepId: number | 'latest' = 'latest') => {
    const current = openWorking.value;
    if (!current || current.messageId !== messageId) return;

    const loadVersion = workingLoadVersion + 1;
    workingLoadVersion = loadVersion;
    openWorking.value = { ...current, loading: true, error: '' };

    const paramsQuery = new URLSearchParams();
    if (stepId !== 'latest') paramsQuery.set('step_id', String(stepId));
    const suffix = paramsQuery.toString() ? `?${paramsQuery.toString()}` : '';

    try {
      const payload = await api.get<WorkingPayload>(`/api/bff/chat-messages/${messageId}/working${suffix}`, {
        showErrorBanner: false,
      });
      if (workingLoadVersion !== loadVersion || openWorking.value?.messageId !== messageId) return;
      const selectedStepId = payload.selected_step_id ?? payload.step?.id ?? null;
      openWorking.value = {
        messageId,
        steps: payload.steps || [],
        selectedStepId,
        selectedStep: payload.step || null,
        selectedLatest: stepId === 'latest' || isLatestStepId(payload.steps || [], selectedStepId),
        open: true,
        loading: false,
        error: '',
      };
    } catch (error) {
      if (workingLoadVersion !== loadVersion || openWorking.value?.messageId !== messageId) return;
      openWorking.value = {
        ...openWorking.value,
        loading: false,
        error: errorMessage(error, 'Failed to load working details.'),
      };
    }
  };

  const toggleWorking = (id: number | null | undefined) => {
    if (!id) return;
    const current = openWorking.value;
    if (current?.messageId === id && current.open) {
      closeWorking();
      return;
    }
    if (current?.messageId === id && current.loading) {
      clearWorking();
      return;
    }

    openWorking.value = {
      ...(current?.messageId === id ? current : {}),
      messageId: id,
      steps: current?.messageId === id ? current.steps : [],
      selectedStepId: current?.messageId === id ? current.selectedStepId : null,
      selectedStep: current?.messageId === id ? current.selectedStep : null,
      selectedLatest: true,
      open: false,
      loading: true,
      error: '',
    };
    void loadWorking(id, 'latest');
  };

  const selectWorkingStep = (messageId: number | null | undefined, stepId: number | null | undefined) => {
    if (!messageId || !stepId) return;
    if (openWorking.value?.messageId !== messageId) return;
    void loadWorking(messageId, stepId);
  };

  const getOpenWorkingPollRequest = (messageId: number) => {
    const state = openWorking.value;
    if (!state || state.messageId !== messageId) return null;
    if (!state.open) return null;
    if (state.selectedLatest) return 'latest';
    return state.selectedStepId && state.selectedStepId > 0 ? String(state.selectedStepId) : 'latest';
  };

  const applyWorkingPoll = (messageId: number, payload: PollResponse['working_open']) => {
    if (!payload || openWorking.value?.messageId !== messageId) return;
    if (!openWorking.value.open) return;
    openWorking.value = {
      ...openWorking.value,
      selectedStepId: payload.selected_step_id ?? payload.step?.id ?? openWorking.value.selectedStepId,
      selectedStep: payload.step || openWorking.value.selectedStep,
      loading: false,
      error: '',
    };
  };

  const retryLastStep = async (msg: ChatBranchMessage) => {
    if (params.readOnly.value) return;
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

      replaceBranch(payload.branch);

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
    if (params.readOnly.value) return;
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
      replaceBranch(payload.branch);
      params.afterBranchSwitched?.();
    } catch (error) {
      console.error(error);
    }
  };

  const extractEditableTextContents = (msg: ChatBranchMessage) => {
    const targets: Array<{ id: number; sequence: number; text: string }> = [];

    for (const part of [...(msg.content?.parts || [])].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0))) {
      if (typeof part.content_id !== 'number') continue;
      targets.push({
        id: part.content_id,
        sequence: part.sequence ?? 0,
        text: String(part.text ?? ''),
      });
    }

    return targets;
  };

  const extractEditableMediaContents = (msg: ChatBranchMessage) => {
    if (!msg.id) return [];
    const attachments: ExistingChatAttachment[] = [];

    for (const content of msg.content?.media || []) {
      const attachment = mapContentToExistingAttachment(content, msg.id);
      if (attachment) attachments.push(attachment);
    }

    return attachments;
  };

  const startEdit = (msg: ChatBranchMessage) => {
    if (params.readOnly.value) return;
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
    if (params.readOnly.value) return;
    if (!msg.id || !params.chatId.value) return;
    if (branchingAssistantId.value === msg.id) return;
    branchingAssistantId.value = msg.id;

    const configReady = await params.waitForConfigSync();
    if (!configReady) {
      branchingAssistantId.value = null;
      alert('Configuration change is still syncing. Please wait before starting a new generation.');
      return;
    }

    const parentId = msg.parent_id ?? null;
    if (!parentId) {
      branchingAssistantId.value = null;
      alert('Cannot branch: missing parent message.');
      return;
    }

    try {
      const payload = await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
        `/api/bff/chats/${params.chatId.value}/generate`,
        { parent_id: parentId }
      );
      replaceBranch(payload.branch);
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
    if (params.readOnly.value) return;
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
    if (params.readOnly.value) return;
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
    if (params.readOnly.value) return;
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
        replaceBranch(payload.branch);
        resetEditState();
      } else {
        const configReady = await params.waitForConfigSync();
        if (!configReady) {
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
        replaceBranch(payload.branch);
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

  watch(
    () => params.branch.value.map((message) => message.id).join(':'),
    () => {
      const messageId = openWorking.value?.messageId;
      if (!messageId) return;
      if (!params.branch.value.some((message) => message.id === messageId)) clearWorking();
    }
  );

  const dispose = async () => {
    clearWorking();
    await params.clearPendingFilesCollection(editPendingFiles);
  };

  return {
    copiedMessageId,
    retryingMessageId,
    branchingAssistantId,
    isBookmarkingMessage,
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
    toggleBookmark,
    branchMessageById,
    retryConfigurationWarning,
    canDeleteMessage,
    deleteMessageTitle,
    confirmAndDeleteMessage,
    isWorkingOpen,
    workingStateFor,
    toggleWorking,
    selectWorkingStep,
    getOpenWorkingPollRequest,
    applyWorkingPoll,
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
