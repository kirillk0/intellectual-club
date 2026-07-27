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

const createRuntime = (messages = [followUp()]) => {
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
    readOnly: computed(() => false),
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
});
