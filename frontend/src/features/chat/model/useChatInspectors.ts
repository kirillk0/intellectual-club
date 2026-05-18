import { computed, ref, type Ref } from 'vue';

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
  composerPendingFiles: Ref<PendingChatFile[]>;
  editPendingFiles: Ref<PendingChatFile[]>;
  editExistingAttachments: Ref<ExistingChatAttachment[]>;
};

type PendingAttachmentScope = 'composer' | 'edit';

type AttachmentPreviewItem =
  | {
      key: string;
      type: 'message';
      messageId: number;
      content: ChatMessageContent;
    }
  | {
      key: string;
      type: 'pending';
      scope: PendingAttachmentScope;
      fileId: string;
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
  const attachmentPreviewItems = ref<AttachmentPreviewItem[]>([]);
  const attachmentPreviewIndex = ref(0);
  const attachmentPreviewCanNavigate = computed(() => attachmentPreviewItems.value.length > 1);
  let attachmentPreviewObjectUrl: string | null = null;

  const previewItemKey = (item: AttachmentPreviewItem) => item.key;
  const messagePreviewKey = (messageId: number, contentId: number) => `message-${messageId}-${contentId}`;
  const pendingPreviewKey = (scope: PendingAttachmentScope, fileId: string) => `pending-${scope}-${fileId}`;
  const sortBySequence = <T extends { sequence?: number | null }>(a: T, b: T) => (a.sequence ?? 0) - (b.sequence ?? 0);
  const normalizePreviewIndex = (index: number, length: number) => ((index % length) + length) % length;

  const getPendingFilesForScope = (scope: PendingAttachmentScope) =>
    scope === 'edit' ? params.editPendingFiles.value : params.composerPendingFiles.value;

  const findPendingAttachment = (fileId: string, scope: PendingAttachmentScope) =>
    getPendingFilesForScope(scope).find((item) => item.id === fileId) || null;

  const buildMessagePreviewItems = (messageId: number, contents: ChatMessageContent[] | null | undefined) =>
    (contents || [])
      .slice()
      .filter((content) => content.kind === 'media' && content.media)
      .sort(sortBySequence)
      .map(
        (content): AttachmentPreviewItem => ({
          key: messagePreviewKey(messageId, Number(content.id || 0)),
          type: 'message',
          messageId,
          content,
        })
      );

  const buildComposerPreviewItems = () =>
    params.composerPendingFiles.value.map(
      (file): AttachmentPreviewItem => ({
        key: pendingPreviewKey('composer', file.id),
        type: 'pending',
        scope: 'composer',
        fileId: file.id,
      })
    );

  const buildEditPreviewItems = () => [
    ...params.editExistingAttachments.value.map(
      (attachment): AttachmentPreviewItem => ({
        key: messagePreviewKey(attachment.messageId, attachment.id),
        type: 'message',
        messageId: attachment.messageId,
        content: attachment.content,
      })
    ),
    ...params.editPendingFiles.value.map(
      (file): AttachmentPreviewItem => ({
        key: pendingPreviewKey('edit', file.id),
        type: 'pending',
        scope: 'edit',
        fileId: file.id,
      })
    ),
  ];

  const revokeAttachmentPreviewObjectUrl = () => {
    if (!attachmentPreviewObjectUrl) return;
    URL.revokeObjectURL(attachmentPreviewObjectUrl);
    attachmentPreviewObjectUrl = null;
  };

  const openMessageAttachmentPreview = async (payload: {
    messageId: number;
    content: ChatMessageContent;
    contents?: ChatMessageContent[] | null;
  }) => {
    const messageId = Number(payload.messageId || 0);
    const contentId = Number(payload.content?.id || 0);
    if (!messageId || !contentId) return;

    const items = buildMessagePreviewItems(messageId, payload.contents?.length ? payload.contents : [payload.content]);
    const currentKey = messagePreviewKey(messageId, contentId);
    const currentIndex = items.findIndex((item) => previewItemKey(item) === currentKey);
    await openAttachmentPreviewItems(items, currentIndex >= 0 ? currentIndex : 0);
  };

  const showAttachmentPreviewItem = async (item: AttachmentPreviewItem) => {
    revokeAttachmentPreviewObjectUrl();

    const token = attachmentPreviewRequestToken.value + 1;
    attachmentPreviewRequestToken.value = token;
    attachmentPreviewOpen.value = true;
    attachmentPreviewError.value = '';
    attachmentPreviewText.value = '';

    if (item.type === 'message') {
      const contentId = Number(item.content?.id || 0);
      const name = getAttachmentName(item.content);
      const mimeType = getAttachmentMimeType(item.content);
      const isImage = Boolean(item.content.media?.is_image);
      const kind = getAttachmentPreviewKind(name, mimeType, isImage);
      const url = contentId ? buildMessageContentFileUrl(item.messageId, contentId) : '';

      attachmentPreviewTitle.value = name;
      attachmentPreviewUrl.value = url;
      attachmentPreviewKind.value = kind;
      attachmentPreviewLoading.value = kind !== 'image' && kind !== 'binary';

      if (kind === 'image' || kind === 'binary' || !url) {
        attachmentPreviewLoading.value = false;
        if (!url) {
          attachmentPreviewError.value = 'Attachment is not available.';
        }
        return;
      }

      try {
        const response = await fetch(url);
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

      return;
    }

    const pending = findPendingAttachment(item.fileId, item.scope);
    if (!pending) {
      attachmentPreviewTitle.value = 'Attachment';
      attachmentPreviewUrl.value = '';
      attachmentPreviewKind.value = 'binary';
      attachmentPreviewLoading.value = false;
      attachmentPreviewError.value = 'Attachment is no longer available.';
      return;
    }

    const isImage = pending.mimeType.trim().toLowerCase().startsWith('image/');
    const kind = getAttachmentPreviewKind(pending.name, pending.mimeType, isImage);
    const objectUrl = URL.createObjectURL(pending.file);

    attachmentPreviewObjectUrl = objectUrl;
    attachmentPreviewTitle.value = pending.name;
    attachmentPreviewUrl.value = objectUrl;
    attachmentPreviewKind.value = kind;
    attachmentPreviewLoading.value = kind !== 'image' && kind !== 'binary';

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

  const openAttachmentPreviewItems = async (items: AttachmentPreviewItem[], index: number) => {
    if (!items.length) return;

    attachmentPreviewItems.value = items;
    attachmentPreviewIndex.value = normalizePreviewIndex(index, items.length);
    await showAttachmentPreviewItem(attachmentPreviewItems.value[attachmentPreviewIndex.value]);
  };

  const openAttachmentPreview = async (payload: {
    messageId: number;
    content: ChatMessageContent;
    contents?: ChatMessageContent[] | null;
  }) => {
    await openMessageAttachmentPreview(payload);
  };

  const openPendingAttachmentPreview = async (
    fileId: string,
    scope: PendingAttachmentScope = 'composer'
  ) => {
    const items = scope === 'edit' ? buildEditPreviewItems() : buildComposerPreviewItems();
    const currentKey = pendingPreviewKey(scope, fileId);
    const currentIndex = items.findIndex((item) => previewItemKey(item) === currentKey);
    if (currentIndex < 0) return;
    await openAttachmentPreviewItems(items, currentIndex);
  };

  const openExistingAttachmentPreview = async (attachment: ExistingChatAttachment) => {
    const items = buildEditPreviewItems();
    const currentKey = messagePreviewKey(attachment.messageId, attachment.id);
    const currentIndex = items.findIndex((item) => previewItemKey(item) === currentKey);

    if (currentIndex >= 0) {
      await openAttachmentPreviewItems(items, currentIndex);
      return;
    }

    await openMessageAttachmentPreview({
      messageId: attachment.messageId,
      content: attachment.content,
      contents: [attachment.content],
    });
  };

  const showPreviousAttachmentPreview = async () => {
    if (!attachmentPreviewItems.value.length) return;
    const nextIndex = normalizePreviewIndex(
      attachmentPreviewIndex.value - 1,
      attachmentPreviewItems.value.length
    );
    attachmentPreviewIndex.value = nextIndex;
    await showAttachmentPreviewItem(attachmentPreviewItems.value[nextIndex]);
  };

  const showNextAttachmentPreview = async () => {
    if (!attachmentPreviewItems.value.length) return;
    const nextIndex = normalizePreviewIndex(
      attachmentPreviewIndex.value + 1,
      attachmentPreviewItems.value.length
    );
    attachmentPreviewIndex.value = nextIndex;
    await showAttachmentPreviewItem(attachmentPreviewItems.value[nextIndex]);
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
    attachmentPreviewItems.value = [];
    attachmentPreviewIndex.value = 0;
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
    attachmentPreviewCanNavigate,
    openAttachmentPreview,
    openPendingAttachmentPreview,
    openExistingAttachmentPreview,
    showPreviousAttachmentPreview,
    showNextAttachmentPreview,
    closeAttachmentPreview,
    dispose,
  };
}
