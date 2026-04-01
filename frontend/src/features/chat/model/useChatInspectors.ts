import { ref, type Ref } from 'vue';

import { api, getApiErrorMessage } from '@/api/client';
import {
  buildMessageContentFileUrl,
  getAttachmentMimeType,
  getAttachmentName,
  getAttachmentPreviewKind,
  type ExistingChatAttachment,
  type PendingChatFile,
} from '@/features/chat/attachments';
import type {
  ChatBranchMessage,
  ChatMessageContent,
  ChatMessageStep,
} from '@/types/api';

type ScrollToLastMessage = (opts?: {
  behavior?: ScrollBehavior;
  block?: ScrollLogicalPosition;
}) => Promise<void> | void;

type Params = {
  compiledPromptText: Ref<string>;
  loadError: Ref<string>;
  branch: Ref<ChatBranchMessage[]>;
  branchMessageById: (messageId: number | null | undefined) => ChatBranchMessage | null;
  retryConfigurationWarning: (message: ChatBranchMessage | null | undefined) => string;
  startPolling: (messageId: number) => Promise<void>;
  scrollToLastMessage: ScrollToLastMessage;
  findPendingAttachment: (fileId: string) => PendingChatFile | null;
};

export function useChatInspectors(params: Params) {
  const errorMessage = (error: unknown, fallback: string) => getApiErrorMessage(error, fallback);
  const confirm = (message: string) => window.confirm(message);
  const alert = (message: string) => window.alert(message);

  const promptModalOpen = ref(false);
  const promptLoading = ref(false);
  const promptError = ref('');
  const promptText = ref('');

  const openPromptModal = async () => {
    promptModalOpen.value = true;
    promptLoading.value = false;
    promptError.value = '';
    promptText.value = params.compiledPromptText.value || '';
  };

  const closePromptModal = () => {
    promptModalOpen.value = false;
    promptLoading.value = false;
    promptError.value = '';
  };

  const fetchStepRawPayload = async (payload: {
    messageId: number;
    stepId: number;
    kind: 'request' | 'response';
  }) => {
    if (!payload.stepId || payload.stepId <= 0) {
      throw new Error('Step is not available');
    }

    const searchParams = new URLSearchParams();
    searchParams.set('kind', payload.kind);

    const response = await api.get<{ step: { raw_request?: unknown; raw_response?: unknown } }>(
      `/api/bff/chat-messages/${payload.messageId}/steps/${payload.stepId}/raw?${searchParams.toString()}`
    );

    return payload.kind === 'request' ? response.step?.raw_request ?? null : response.step?.raw_response ?? null;
  };

  const stepDetailsOpen = ref(false);
  const stepDetailsStep = ref<ChatMessageStep | null>(null);
  const stepDetailsMessageId = ref<number | null>(null);
  const stepDetailsMessageStatus = ref<ChatBranchMessage['status'] | null>(null);
  const stepDetailsShowBilling = ref(false);
  const stepDetailsShowResponse = ref(false);
  const stepDetailsRetryFromStepPending = ref(false);

  const stepDetailsRequestLoading = ref(false);
  const stepDetailsRequestError = ref('');
  const stepDetailsRequestPayload = ref<unknown>(null);
  const stepDetailsRequestToken = ref(0);

  const stepDetailsResponseLoading = ref(false);
  const stepDetailsResponseError = ref('');
  const stepDetailsResponsePayload = ref<unknown>(null);
  const stepDetailsResponseToken = ref(0);

  const loadStepDetailsRaw = async (
    kind: 'request' | 'response',
    payload: { messageId: number; stepId: number }
  ) => {
    const isRequest = kind === 'request';
    const token = (isRequest ? stepDetailsRequestToken : stepDetailsResponseToken).value + 1;

    if (isRequest) {
      stepDetailsRequestToken.value = token;
      stepDetailsRequestLoading.value = true;
      stepDetailsRequestError.value = '';
      stepDetailsRequestPayload.value = null;
    } else {
      stepDetailsResponseToken.value = token;
      stepDetailsResponseLoading.value = true;
      stepDetailsResponseError.value = '';
      stepDetailsResponsePayload.value = null;
    }

    try {
      const rawPayload = await fetchStepRawPayload({
        messageId: payload.messageId,
        stepId: payload.stepId,
        kind,
      });

      if (isRequest) {
        if (stepDetailsRequestToken.value !== token) return;
        stepDetailsRequestPayload.value = rawPayload;
      } else {
        if (stepDetailsResponseToken.value !== token) return;
        stepDetailsResponsePayload.value = rawPayload;
      }
    } catch (error) {
      const errorText =
        error instanceof Error && error.message === 'Step is not available'
          ? error.message
          : 'Failed to load payload';

      if (isRequest) {
        if (stepDetailsRequestToken.value !== token) return;
        stepDetailsRequestError.value = errorText;
      } else {
        if (stepDetailsResponseToken.value !== token) return;
        stepDetailsResponseError.value = errorText;
      }
    } finally {
      if (isRequest) {
        if (stepDetailsRequestToken.value === token) {
          stepDetailsRequestLoading.value = false;
        }
      } else if (stepDetailsResponseToken.value === token) {
        stepDetailsResponseLoading.value = false;
      }
    }
  };

  const openStepDetails = (payload: {
    messageId: number;
    messageStatus: ChatBranchMessage['status'];
    step: ChatMessageStep;
    closed: boolean;
  }) => {
    stepDetailsOpen.value = true;
    stepDetailsStep.value = payload.step;
    stepDetailsMessageId.value = payload.messageId;
    stepDetailsMessageStatus.value = payload.messageStatus;
    stepDetailsShowBilling.value = Boolean(payload.closed);
    stepDetailsShowResponse.value = Boolean(payload.closed);
    stepDetailsRetryFromStepPending.value = false;

    const stepId = Number(payload.step.id || 0);
    void loadStepDetailsRaw('request', { messageId: payload.messageId, stepId });
    if (payload.closed) {
      void loadStepDetailsRaw('response', { messageId: payload.messageId, stepId });
    } else {
      stepDetailsResponseLoading.value = false;
      stepDetailsResponseError.value = '';
      stepDetailsResponsePayload.value = null;
      stepDetailsResponseToken.value += 1;
    }
  };

  const closeStepDetails = () => {
    stepDetailsOpen.value = false;
    stepDetailsStep.value = null;
    stepDetailsMessageId.value = null;
    stepDetailsMessageStatus.value = null;
    stepDetailsShowBilling.value = false;
    stepDetailsShowResponse.value = false;
    stepDetailsRetryFromStepPending.value = false;
    stepDetailsRequestLoading.value = false;
    stepDetailsRequestError.value = '';
    stepDetailsRequestPayload.value = null;
    stepDetailsRequestToken.value += 1;
    stepDetailsResponseLoading.value = false;
    stepDetailsResponseError.value = '';
    stepDetailsResponsePayload.value = null;
    stepDetailsResponseToken.value += 1;
  };

  const retryFromStep = async () => {
    const messageId = stepDetailsMessageId.value;
    const step = stepDetailsStep.value;
    const stepId = Number(step?.id || 0);

    if (!messageId || !stepId) return;
    if (stepDetailsRetryFromStepPending.value) return;

    if (stepDetailsMessageStatus.value === 'generating') {
      alert('Retry from this step is available after generation stops.');
      return;
    }

    const stepNumber =
      typeof step?.sequence === 'number' && Number.isFinite(step.sequence) && step.sequence > 0
        ? step.sequence
        : '—';

    const retryWarning = params.retryConfigurationWarning(params.branchMessageById(messageId));
    const confirmText = [
      `Retry from step ${stepNumber}? This will delete this step and all following steps for this message.`,
      retryWarning,
    ]
      .filter((line) => line)
      .join('\n\n');

    if (!confirm(confirmText)) return;

    stepDetailsRetryFromStepPending.value = true;
    params.loadError.value = '';

    try {
      const payload = await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
        `/api/bff/chat-messages/${messageId}/steps/${stepId}/retry-from-step`,
        {}
      );

      params.branch.value = payload.branch || [];
      const generationId = payload.generation?.message_id;
      closeStepDetails();

      if (generationId) {
        await params.startPolling(generationId);
      }

      void params.scrollToLastMessage({ behavior: 'smooth', block: 'end' });
    } catch (error) {
      console.error(error);
      alert(errorMessage(error, 'Failed to retry from this step.'));
    } finally {
      stepDetailsRetryFromStepPending.value = false;
    }
  };

  const contentFullOpen = ref(false);
  const contentFullTitle = ref('Tool result');
  const contentFullLoading = ref(false);
  const contentFullError = ref('');
  const contentFullText = ref('');
  const contentFullRequestToken = ref(0);

  const openContentFull = async (payload: {
    messageId: number;
    contentId: number;
    title?: string;
  }) => {
    contentFullOpen.value = true;
    contentFullTitle.value = payload.title || 'Tool result';
    contentFullLoading.value = true;
    contentFullError.value = '';
    contentFullText.value = '';

    const token = contentFullRequestToken.value + 1;
    contentFullRequestToken.value = token;

    try {
      if (!payload.contentId || payload.contentId <= 0) {
        throw new Error('Content is not available');
      }

      const response = await api.get<{ content: { content_text?: string | null } }>(
        `/api/bff/chat-messages/${payload.messageId}/contents/${payload.contentId}/full`
      );

      if (contentFullRequestToken.value !== token) return;
      contentFullText.value = String(response.content?.content_text ?? '');
    } catch (error) {
      if (contentFullRequestToken.value !== token) return;
      contentFullError.value =
        error instanceof Error && error.message === 'Content is not available'
          ? error.message
          : 'Failed to load content';
    } finally {
      if (contentFullRequestToken.value === token) {
        contentFullLoading.value = false;
      }
    }
  };

  const closeContentFull = () => {
    contentFullOpen.value = false;
    contentFullTitle.value = 'Tool result';
    contentFullLoading.value = false;
    contentFullError.value = '';
    contentFullText.value = '';
    contentFullRequestToken.value += 1;
  };

  const attachmentPreviewOpen = ref(false);
  const attachmentPreviewTitle = ref('Attachment');
  const attachmentPreviewUrl = ref('');
  const attachmentPreviewKind = ref<'image' | 'text' | 'markdown' | 'binary'>('binary');
  const attachmentPreviewLoading = ref(false);
  const attachmentPreviewError = ref('');
  const attachmentPreviewText = ref('');
  const attachmentPreviewRequestToken = ref(0);
  let attachmentPreviewObjectUrl: string | null = null;

  const revokeAttachmentPreviewObjectUrl = () => {
    if (!attachmentPreviewObjectUrl) return;
    URL.revokeObjectURL(attachmentPreviewObjectUrl);
    attachmentPreviewObjectUrl = null;
  };

  const openAttachmentPreview = async (payload: {
    messageId: number;
    content: ChatMessageContent;
  }) => {
    const messageId = Number(payload.messageId || 0);
    const contentId = Number(payload.content?.id || 0);
    const name = getAttachmentName(payload.content);
    const mimeType = getAttachmentMimeType(payload.content);
    const isImage = Boolean(payload.content.media?.is_image);

    if (!messageId || !contentId) return;

    revokeAttachmentPreviewObjectUrl();
    attachmentPreviewOpen.value = true;
    attachmentPreviewTitle.value = name;
    attachmentPreviewUrl.value = buildMessageContentFileUrl(messageId, contentId);
    attachmentPreviewKind.value = getAttachmentPreviewKind(name, mimeType, isImage);
    attachmentPreviewLoading.value = attachmentPreviewKind.value !== 'image';
    attachmentPreviewError.value = '';
    attachmentPreviewText.value = '';

    const token = attachmentPreviewRequestToken.value + 1;
    attachmentPreviewRequestToken.value = token;

    if (attachmentPreviewKind.value === 'image' || attachmentPreviewKind.value === 'binary') {
      attachmentPreviewLoading.value = false;
      return;
    }

    try {
      const response = await fetch(attachmentPreviewUrl.value);
      if (!response.ok) throw new Error(`Failed to load attachment (${response.status})`);
      const text = await response.text();
      if (attachmentPreviewRequestToken.value !== token) return;
      attachmentPreviewText.value = text;
    } catch (error) {
      if (attachmentPreviewRequestToken.value !== token) return;
      attachmentPreviewError.value = error instanceof Error ? error.message : 'Failed to load attachment';
    } finally {
      if (attachmentPreviewRequestToken.value === token) {
        attachmentPreviewLoading.value = false;
      }
    }
  };

  const openPendingAttachmentPreview = async (fileId: string) => {
    const pending = params.findPendingAttachment(fileId);
    if (!pending) return;

    const isImage = pending.mimeType.trim().toLowerCase().startsWith('image/');
    const kind = getAttachmentPreviewKind(pending.name, pending.mimeType, isImage);
    const objectUrl = URL.createObjectURL(pending.file);
    const token = attachmentPreviewRequestToken.value + 1;

    attachmentPreviewRequestToken.value = token;
    revokeAttachmentPreviewObjectUrl();
    attachmentPreviewObjectUrl = objectUrl;
    attachmentPreviewOpen.value = true;
    attachmentPreviewTitle.value = pending.name;
    attachmentPreviewUrl.value = objectUrl;
    attachmentPreviewKind.value = kind;
    attachmentPreviewLoading.value = kind !== 'image' && kind !== 'binary';
    attachmentPreviewError.value = '';
    attachmentPreviewText.value = '';

    if (kind === 'image' || kind === 'binary') {
      attachmentPreviewLoading.value = false;
      return;
    }

    try {
      const text = await pending.file.text();
      if (attachmentPreviewRequestToken.value !== token) return;
      attachmentPreviewText.value = text;
    } catch (error) {
      if (attachmentPreviewRequestToken.value !== token) return;
      attachmentPreviewError.value = error instanceof Error ? error.message : 'Failed to load attachment';
    } finally {
      if (attachmentPreviewRequestToken.value === token) {
        attachmentPreviewLoading.value = false;
      }
    }
  };

  const openExistingAttachmentPreview = async (attachment: ExistingChatAttachment) => {
    await openAttachmentPreview({
      messageId: attachment.messageId,
      content: attachment.content,
    });
  };

  const closeAttachmentPreview = () => {
    revokeAttachmentPreviewObjectUrl();
    attachmentPreviewOpen.value = false;
    attachmentPreviewTitle.value = 'Attachment';
    attachmentPreviewUrl.value = '';
    attachmentPreviewKind.value = 'binary';
    attachmentPreviewLoading.value = false;
    attachmentPreviewError.value = '';
    attachmentPreviewText.value = '';
    attachmentPreviewRequestToken.value += 1;
  };

  const dispose = () => {
    revokeAttachmentPreviewObjectUrl();
  };

  return {
    promptModalOpen,
    promptLoading,
    promptError,
    promptText,
    openPromptModal,
    closePromptModal,
    stepDetailsOpen,
    stepDetailsStep,
    stepDetailsMessageId,
    stepDetailsMessageStatus,
    stepDetailsShowBilling,
    stepDetailsShowResponse,
    stepDetailsRetryFromStepPending,
    stepDetailsRequestLoading,
    stepDetailsRequestError,
    stepDetailsRequestPayload,
    stepDetailsResponseLoading,
    stepDetailsResponseError,
    stepDetailsResponsePayload,
    openStepDetails,
    closeStepDetails,
    retryFromStep,
    contentFullOpen,
    contentFullTitle,
    contentFullLoading,
    contentFullError,
    contentFullText,
    openContentFull,
    closeContentFull,
    attachmentPreviewOpen,
    attachmentPreviewTitle,
    attachmentPreviewUrl,
    attachmentPreviewKind,
    attachmentPreviewLoading,
    attachmentPreviewError,
    attachmentPreviewText,
    openAttachmentPreview,
    openPendingAttachmentPreview,
    openExistingAttachmentPreview,
    closeAttachmentPreview,
    dispose,
  };
}
