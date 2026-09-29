import { computed, ref } from 'vue';

const apiMocks = vi.hoisted(() => ({
  del: vi.fn(),
  patch: vi.fn(),
  post: vi.fn(),
  isHttpError: vi.fn(),
}));

vi.mock('@/api/client', () => ({
  api: apiMocks,
  getApiErrorMessage: (_error: unknown, fallback: string) => fallback,
  isHttpError: apiMocks.isHttpError,
}));

import {
  queuedMessageAttachments,
  queuedMessageText,
  useChatQueueRuntime,
} from '@/features/chat/model/useChatQueueRuntime';
import type { ChatQueuedMessage } from '@/features/chat/model/chatViewModel.shared';

const followUp = (status: 'pending' | 'blocked' = 'pending'): ChatQueuedMessage => ({
  id: 10,
  chat_id: 2,
  kind: 'follow_up',
  status,
  anchor_message_id: 8,
  blocked_reason: status === 'blocked' ? 'generation_error' : null,
  contents: [
    { id: 101, sequence: 1, kind: 'text', content_text: 'First\nfollow-up' },
    {
      id: 102,
      sequence: 2,
      kind: 'media',
      file: {
        id: 501,
        external_id: 'file-501',
        filename: 'notes.txt',
        mime_type: 'text/plain',
        size_bytes: 12,
      },
    },
  ],
});

const failedSteer = (): ChatQueuedMessage => ({
  id: 20,
  chat_id: 2,
  kind: 'steer',
  status: 'blocked',
  target_generation_message_id: 8,
  blocked_reason: 'steering_failed',
  attempt_count: 1,
  contents: [{ id: 201, sequence: 1, kind: 'text', content_text: 'Failed instruction' }],
});

const createRuntime = (messages = [followUp()], readOnly = false) => {
  const queuedMessages = ref<ChatQueuedMessage[]>(messages);
  const loadError = ref('');
  const refreshChat = vi.fn().mockResolvedValue(undefined);
  const ensurePendingFilesUploaded = vi.fn().mockResolvedValue(['upload-1']);
  const clearPendingFilesCollection = vi.fn(async (files: { value: unknown[] }) => {
    files.value = [];
  });

  const runtime = useChatQueueRuntime({
    chatId: computed(() => 2),
    queuedMessages,
    readOnly: computed(() => readOnly),
    loadError,
    fileUploadPolicy: computed(() => ({
      allowsFiles: true,
      imagesOnly: false,
      maxFileSizeBytes: 1024,
      accept: '',
    })),
    ensurePendingFilesUploaded,
    removePendingFileFromCollection: vi.fn(async () => undefined),
    clearPendingFilesCollection,
    refreshChat,
  });

  return { runtime, queuedMessages, loadError, refreshChat };
};

describe('chat queue runtime', () => {
  beforeEach(() => {
    apiMocks.del.mockReset();
    apiMocks.patch.mockReset();
    apiMocks.post.mockReset();
    apiMocks.isHttpError.mockReset().mockReturnValue(false);
    vi.restoreAllMocks();
  });

  it('normalizes conventional queued text and attachment payloads', () => {
    expect(queuedMessageText(followUp())).toBe('First\nfollow-up');
    expect(queuedMessageAttachments(followUp())).toEqual([
      expect.objectContaining({
        id: 102,
        queuedMessageId: 10,
        name: 'notes.txt',
        mimeType: 'text/plain',
        size: 12,
      }),
    ]);
  });

  it('edits text and removes attachments without changing queue identity', async () => {
    const updated = {
      ...followUp(),
      contents: [{ id: 101, sequence: 1, kind: 'text', content_text: 'Updated' }],
    } satisfies ChatQueuedMessage;
    apiMocks.patch.mockResolvedValueOnce({ queued_message: updated });
    const { runtime, queuedMessages } = createRuntime();

    runtime.startEdit(followUp());
    runtime.editContents.value = ['Updated'];
    runtime.removeEditExistingAttachment(102);
    await runtime.saveEdit();

    expect(apiMocks.patch).toHaveBeenCalledWith('/api/bff/chat-queued-messages/10', {
      content: 'Updated',
      remove_content_ids: [102],
    });
    expect(queuedMessages.value).toEqual([updated]);
    expect(runtime.editingQueuedMessage.value).toBeNull();
  });

  it('removes an editable item using the authoritative canceled response', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    apiMocks.del.mockResolvedValueOnce({
      queued_message: { ...followUp(), status: 'canceled' },
    });
    const { runtime, queuedMessages } = createRuntime();

    await runtime.removeFromQueue(followUp());

    expect(apiMocks.del).toHaveBeenCalledWith('/api/bff/chat-queued-messages/10');
    expect(queuedMessages.value).toEqual([]);
  });

  it('sends only the follow-up head and refreshes server generation state', async () => {
    apiMocks.post.mockResolvedValueOnce({
      queued_message: { ...followUp(), status: 'delivered' },
    });
    const { runtime, refreshChat } = createRuntime();

    await runtime.sendNext(followUp('blocked'));

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-queued-messages/10/send-next', {});
    expect(refreshChat).toHaveBeenCalledTimes(1);
  });

  it('keeps quarantined steering visible and editable without treating it as follow-up backlog', async () => {
    const failed = failedSteer();
    const edited = {
      ...failed,
      contents: [{ id: 201, sequence: 1, kind: 'text', content_text: 'Fixed instruction' }],
    } satisfies ChatQueuedMessage;
    apiMocks.patch.mockResolvedValueOnce({ queued_message: edited });
    const { runtime, queuedMessages } = createRuntime([failed]);

    expect(runtime.visibleQueuedMessages.value).toEqual([failed]);
    expect(runtime.hasFollowUpBacklog.value).toBe(false);
    expect(runtime.headFollowUpId.value).toBeNull();
    runtime.startEdit(failed);
    runtime.editContents.value = ['Fixed instruction'];
    await runtime.saveEdit();

    expect(queuedMessages.value).toEqual([edited]);
    expect(queuedMessages.value[0]?.status).toBe('blocked');
    expect(apiMocks.post).not.toHaveBeenCalled();
    expect(runtime.editingQueuedMessage.value).toBeNull();
  });

  it('retries quarantined steering independently of the follow-up head', async () => {
    const failed = failedSteer();
    const pending = { ...failed, status: 'pending', blocked_reason: null } satisfies ChatQueuedMessage;
    apiMocks.post.mockResolvedValueOnce({ queued_message: pending });
    const { runtime, queuedMessages, refreshChat } = createRuntime([followUp('blocked'), failed]);

    await runtime.sendNext(failed);

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-queued-messages/20/send-next', {});
    expect(queuedMessages.value).toEqual([followUp('blocked'), pending]);
    expect(refreshChat).toHaveBeenCalledTimes(1);
    expect(runtime.queueActionId.value).toBeNull();
  });

  it('uses the authoritative terminal retry response without unblocking a canceled follow-up', async () => {
    const failed = failedSteer();
    const converted = {
      ...failed,
      kind: 'follow_up',
      target_generation_message_id: null,
      anchor_message_id: 8,
      blocked_reason: 'generation_canceled',
    } satisfies ChatQueuedMessage;
    apiMocks.post.mockResolvedValueOnce({ queued_message: converted });
    const { runtime, queuedMessages } = createRuntime([failed]);

    await runtime.sendNext(failed);

    expect(queuedMessages.value).toEqual([converted]);
    expect(runtime.headFollowUpId.value).toBe(failed.id);
    expect(apiMocks.post).toHaveBeenCalledTimes(1);
  });

  it('removes a terminal retry routed into a handoff child from the source panel', async () => {
    const failed = failedSteer();
    apiMocks.post.mockResolvedValueOnce({
      queued_message: { ...failed, kind: 'follow_up', chat_id: 3, status: 'pending', blocked_reason: null },
    });
    const { runtime, queuedMessages, refreshChat } = createRuntime([followUp(), failed]);

    await runtime.sendNext(failed);

    expect(queuedMessages.value).toEqual([followUp()]);
    expect(refreshChat).toHaveBeenCalledTimes(1);
  });

  it('keeps a rejected retry and any unsaved edit draft while refreshing the authoritative queue', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => undefined);
    const error = { status: 409, bodyJson: { code: 'queued_steering_changed' } };
    apiMocks.isHttpError.mockImplementation((value) => value === error);
    apiMocks.post.mockRejectedValueOnce(error);
    const failed = failedSteer();
    const { runtime, queuedMessages, loadError, refreshChat } = createRuntime([failed]);
    runtime.startEdit(failed);
    runtime.editContents.value = ['Unsaved correction'];

    await runtime.sendNext(failed);

    expect(queuedMessages.value).toEqual([failed]);
    expect(runtime.editContents.value).toEqual(['Unsaved correction']);
    expect(runtime.editingQueuedMessage.value?.id).toBe(failed.id);
    expect(loadError.value).toBe('This steering message changed. Refresh and try again.');
    expect(refreshChat).toHaveBeenCalledTimes(1);
    expect(runtime.queueActionId.value).toBeNull();
  });

  it('retains a refused quarantined edit draft without issuing a retry', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => undefined);
    apiMocks.patch.mockRejectedValueOnce(new Error('refused'));
    const failed = failedSteer();
    const { runtime, queuedMessages } = createRuntime([failed]);
    runtime.startEdit(failed);
    runtime.editContents.value = ['Correction'];

    await runtime.saveEdit();

    expect(runtime.editContents.value).toEqual(['Correction']);
    expect(runtime.editingQueuedMessage.value?.id).toBe(failed.id);
    expect(runtime.editError.value).toBe('Failed to update queued message.');
    expect(queuedMessages.value).toEqual([failed]);
    expect(apiMocks.post).not.toHaveBeenCalled();
  });

  it('does not retry pending steering, unrelated blocked entries, non-head follow-ups or read-only queues', async () => {
    const { runtime } = createRuntime([followUp(), failedSteer()]);
    await runtime.sendNext({ ...failedSteer(), status: 'pending', blocked_reason: null });
    await runtime.sendNext({ ...failedSteer(), blocked_reason: 'generation_error' });
    await runtime.sendNext({ ...followUp(), id: 30 });
    const readonly = createRuntime([failedSteer()], true);
    await readonly.runtime.sendNext(failedSteer());
    expect(apiMocks.post).not.toHaveBeenCalled();
  });

});
