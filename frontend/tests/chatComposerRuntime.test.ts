import { computed, ref } from 'vue';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  isHttpError: vi.fn(),
  post: vi.fn(),
}));

vi.mock('@/api/client', () => ({
  api: apiMocks,
  getApiErrorMessage: (_error: unknown, fallback: string) => fallback,
  isHttpError: apiMocks.isHttpError,
}));

vi.mock('@/features/chat/chatEvents', () => ({
  publishChatChange: vi.fn(),
}));

import { useChatComposerRuntime } from '@/features/chat/model/useChatComposerRuntime';
import type { PendingChatFile } from '@/features/chat/attachments';
import type { ChatBranchMessage } from '@/types/api';

const pendingFile = (): PendingChatFile => ({
  id: 'pending-1',
  file: new File(['file'], 'note.txt', { type: 'text/plain' }),
  name: 'note.txt',
  size: 4,
  mimeType: 'text/plain',
  uploadId: null,
  uploadStatus: 'idle',
  uploadedBytes: 0,
  progress: 0,
  speedBps: 0,
  etaSeconds: null,
  abortHandle: null,
  error: '',
});

const createRuntime = (activeMessageId: number | null, supportsSteering = true) => {
  const branch = ref<ChatBranchMessage[]>(
    activeMessageId
      ? [{ id: activeMessageId, role: 'assistant', status: 'generating', llm_configuration_id: 27 }]
      : []
  );
  const activeGenerationId = ref(activeMessageId);
  const loadError = ref('');

  const runtime = useChatComposerRuntime({
    chatId: computed(() => 12),
    branch,
    readOnly: computed(() => false),
    loadError,
    fileUploadPolicy: computed(() => ({
      allowsFiles: true,
      imagesOnly: false,
      maxFileSizeBytes: 1024,
      accept: '',
    })),
    waitForConfigSync: async () => true,
    activeGenerationId,
    cancelingGenerationId: ref(null),
    supportsSteering: computed(() => supportsSteering),
    autoScrollEnabled: computed(() => false),
    scrollToLastMessage: vi.fn(),
  });

  return { runtime, branch, activeGenerationId, loadError };
};

const completedPoll = (messageId: number) => ({
  message_id: messageId,
  runtime: false,
  status: 'done',
});

describe('chat composer runtime', () => {
  beforeEach(() => {
    window.localStorage.clear();
    apiMocks.get.mockReset();
    apiMocks.isHttpError.mockReset().mockReturnValue(false);
    apiMocks.post.mockReset();
  });

  it('selects Send or Continue from the idle payload without trimming text', () => {
    const { runtime } = createRuntime(null);

    expect(runtime.sendButtonLabel.value).toBe('Continue');
    runtime.draft.value = '   ';
    expect(runtime.hasSendPayload.value).toBe(true);
    expect(runtime.sendButtonLabel.value).toBe('Send');

    runtime.draft.value = '';
    runtime.pendingFiles.value = [pendingFile()];
    expect(runtime.hasSendPayload.value).toBe(true);
    expect(runtime.sendButtonLabel.value).toBe('Send');
  });

  it('steers with text only, keeps pending files, and clears the acknowledged draft', async () => {
    apiMocks.post.mockResolvedValueOnce({ status: 'ok', message_id: 31, step_id: 4 });
    apiMocks.get.mockResolvedValueOnce(completedPoll(31));
    const { runtime } = createRuntime(31);
    const file = pendingFile();
    runtime.pendingFiles.value = [file];
    runtime.draft.value = 'change direction';

    expect(runtime.canSteerGeneration.value).toBe(true);
    await runtime.steerGeneration();

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-messages/31/steer', {
      content: 'change direction',
    });
    expect(runtime.draft.value).toBe('');
    expect(runtime.pendingFiles.value).toEqual([file]);
    expect(apiMocks.get).toHaveBeenCalledWith(
      '/api/bff/chat-messages/31/poll',
      expect.objectContaining({ showErrorBanner: false })
    );
  });

  it('routes the shared Ctrl/Cmd+Enter submit action to steering during generation', async () => {
    apiMocks.post.mockResolvedValueOnce({ status: 'ok', message_id: 31, step_id: 4 });
    apiMocks.get.mockResolvedValueOnce(completedPoll(31));
    const { runtime } = createRuntime(31);
    runtime.draft.value = 'shortcut direction';

    await runtime.submitComposer();

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-messages/31/steer', {
      content: 'shortcut direction',
    });
  });

  it('preserves the draft when steering is rejected', async () => {
    apiMocks.post.mockRejectedValueOnce(new Error('conflict'));
    const { runtime, loadError } = createRuntime(31);
    runtime.draft.value = 'stop';

    await runtime.steerGeneration();

    expect(runtime.draft.value).toBe('stop');
    expect(loadError.value).toBe('Failed to steer generation.');
  });

  it('localizes a structured steering rejection', async () => {
    const error = { bodyJson: { code: 'generation_not_active' } };
    apiMocks.isHttpError.mockImplementation((value) => value === error);
    apiMocks.post.mockRejectedValueOnce(error);
    const { runtime, loadError } = createRuntime(31);
    runtime.draft.value = 'stop';

    await runtime.steerGeneration();

    expect(runtime.draft.value).toBe('stop');
    expect(loadError.value).toBe('Generation is no longer active.');
  });

  it('does not clear text typed while steering is being acknowledged', async () => {
    let acknowledge!: (value: { status: 'ok'; message_id: number; step_id: number }) => void;
    apiMocks.post.mockReturnValueOnce(new Promise((resolve) => {
      acknowledge = resolve;
    }));
    apiMocks.get.mockResolvedValueOnce(completedPoll(31));
    const { runtime } = createRuntime(31);
    runtime.draft.value = 'first direction';

    const request = runtime.steerGeneration();
    runtime.draft.value = 'new draft';
    acknowledge({ status: 'ok', message_id: 31, step_id: 4 });
    await request;

    expect(runtime.draft.value).toBe('new draft');
  });

  it('hides steering when the active configuration does not support it', () => {
    const { runtime } = createRuntime(31, false);
    runtime.draft.value = 'stop';

    expect(runtime.canSteerGeneration.value).toBe(false);
  });
});
