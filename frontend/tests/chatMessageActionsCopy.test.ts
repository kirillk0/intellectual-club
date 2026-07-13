import { computed, ref } from 'vue';

import { useChatMessageActions } from '@/features/chat/model/useChatMessageActions';
import type { ChatBranchMessage } from '@/types/api';

const copyTextWithFallback = vi.hoisted(() => vi.fn());

vi.mock('@/utils/clipboard', () => ({ copyTextWithFallback }));

const message: ChatBranchMessage = {
  id: 10,
  role: 'assistant',
  status: 'done',
  content: {
    parts: [
      {
        content_id: 1,
        sequence: 0,
        text: 'First answer',
        item_type: 'answer',
        step_sequence: 1,
        item_sequence: 1,
      },
      {
        content_id: 2,
        sequence: 0,
        text: 'Steering instruction',
        item_type: 'steering',
        step_sequence: 1,
        item_sequence: 2,
      },
      {
        content_id: 3,
        sequence: 0,
        text: 'Final answer',
        item_type: 'answer',
        step_sequence: 2,
        item_sequence: 1,
      },
    ],
    media: [],
  },
};

describe('chat message copy action', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    copyTextWithFallback.mockResolvedValue(true);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('copies the final answer first and all answer items on a repeated click', async () => {
    const actions = useChatMessageActions({
      chatId: computed(() => 1),
      chat: ref(null),
      readOnly: computed(() => false),
      branch: ref([message]),
      selectedConfig: ref(''),
      fileUploadPolicy: computed(() => ({
        allowsFiles: true,
        imagesOnly: false,
        maxFileSizeBytes: 10_000,
        accept: '*/*',
      })),
      waitForConfigSync: async () => true,
      messageConfigLabel: () => '',
      startPolling: async () => undefined,
      scrollToLastMessage: () => undefined,
      ensurePendingFilesUploaded: async () => [],
      removePendingFileFromCollection: async () => undefined,
      clearPendingFilesCollection: async () => undefined,
      pushChatRoute: () => undefined,
    });

    await actions.copyMessage(message);
    expect(actions.copiedAllMessageId.value).toBeNull();

    await actions.copyMessage(message);
    expect(actions.copiedAllMessageId.value).toBe(message.id);

    expect(copyTextWithFallback).toHaveBeenNthCalledWith(1, 'Final answer', {
      promptLabel: 'Copy the message text manually:',
    });
    expect(copyTextWithFallback).toHaveBeenNthCalledWith(2, 'First answer\n\nFinal answer', {
      promptLabel: 'Copy the message text manually:',
    });

    await actions.dispose();
  });
});
