import { computed, nextTick, ref } from 'vue';

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
import type { ChatQueuedMessage } from '@/features/chat/model/chatViewModel.shared';
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

const uploadedPendingFile = (id = 'pending-1'): PendingChatFile => ({
  ...pendingFile(),
  id,
  uploadId: `upload-${id}`,
  uploadStatus: 'uploaded',
  uploadedBytes: 4,
  progress: 1,
});

const queuedMessage = (id = 70): ChatQueuedMessage => ({
  id,
  chat_id: 12,
  kind: 'follow_up',
  status: 'pending',
  anchor_message_id: 31,
  contents: [{ id: id * 10, sequence: 1, kind: 'text', content_text: 'queued' }],
});

const queuedSteer = (id = 72): ChatQueuedMessage => ({
  id,
  chat_id: 12,
  kind: 'steer',
  status: 'pending',
  target_generation_message_id: 31,
  contents: [{ id: id * 10, sequence: 1, kind: 'text', content_text: 'change direction' }],
});

const createRuntime = (
  activeMessageId: number | null,
  supportsSteering = true,
  autoScrollEnabled = false,
  initialQueue: ChatQueuedMessage[] = []
) => {
  const branch = ref<ChatBranchMessage[]>(
    activeMessageId
      ? [{ id: activeMessageId, role: 'assistant', status: 'generating', llm_configuration_id: 27 }]
      : []
  );
  const activeGenerationId = ref(activeMessageId);
  const loadError = ref('');
  const queuedMessages = ref(initialQueue);
  const onQueuedMessageCreated = vi.fn();
  const onQueuedMessagesUpdated = vi.fn();

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
    queuedMessages,
    supportsSteering: computed(() => supportsSteering),
    autoScrollEnabled: computed(() => autoScrollEnabled),
    scrollToLastMessage: vi.fn(),
    onQueuedMessageCreated,
    onQueuedMessagesUpdated,
  });

  return {
    runtime,
    branch,
    activeGenerationId,
    loadError,
    queuedMessages,
    onQueuedMessageCreated,
    onQueuedMessagesUpdated,
  };
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

  afterEach(() => {
    document.body.innerHTML = '';
    Reflect.deleteProperty(document, 'scrollingElement');
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
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
    apiMocks.post.mockResolvedValueOnce({ queued_message: queuedSteer() });
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
    apiMocks.post.mockResolvedValueOnce({ queued_message: queuedSteer() });
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
    let acknowledge!: (value: { queued_message: ChatQueuedMessage }) => void;
    apiMocks.post.mockReturnValueOnce(new Promise((resolve) => {
      acknowledge = resolve;
    }));
    apiMocks.get.mockResolvedValueOnce(completedPoll(31));
    const { runtime } = createRuntime(31);
    runtime.draft.value = 'first direction';

    const request = runtime.steerGeneration();
    runtime.draft.value = 'new draft';
    acknowledge({ queued_message: queuedSteer() });
    await request;

    expect(runtime.draft.value).toBe('new draft');
  });

  it('queues text and files while generating and clears only the acknowledged snapshot', async () => {
    let acknowledge!: (value: { queued_message: ChatQueuedMessage }) => void;
    apiMocks.post.mockReturnValueOnce(new Promise((resolve) => {
      acknowledge = resolve;
    }));
    const { runtime, onQueuedMessageCreated } = createRuntime(31);
    const submittedFile = uploadedPendingFile('submitted');
    const laterFile = uploadedPendingFile('later');
    runtime.pendingFiles.value = [submittedFile];
    runtime.draft.value = 'first follow-up';

    const request = runtime.queueMessage();
    await vi.waitFor(() => expect(apiMocks.post).toHaveBeenCalledTimes(1));
    runtime.draft.value = 'new draft';
    runtime.pendingFiles.value = [...runtime.pendingFiles.value, laterFile];
    acknowledge({ queued_message: queuedMessage() });
    await request;

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-generation/12/queue', {
      content: 'first follow-up',
      upload_ids: ['upload-submitted'],
    });
    expect(runtime.draft.value).toBe('new draft');
    expect(runtime.pendingFiles.value).toEqual([laterFile]);
    expect(onQueuedMessageCreated).toHaveBeenCalledWith(queuedMessage());
  });

  it('appends composer submissions to an existing follow-up backlog', async () => {
    apiMocks.post.mockResolvedValueOnce({ queued_message: queuedMessage(71) });
    const { runtime } = createRuntime(null, true, false, [queuedMessage()]);
    runtime.draft.value = 'tail';

    await runtime.submitComposer();

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-generation/12/queue', {
      content: 'tail',
    });
    expect(runtime.sendButtonLabel.value).toBe('Queue');
  });

  it.each(['queue_not_empty', 'generation_active'])(
    'falls back to enqueue when a direct send races with %s',
    async (code) => {
      const conflict = { status: 409, bodyJson: { code } };
      apiMocks.isHttpError.mockImplementation((value) => value === conflict);
      apiMocks.post
        .mockRejectedValueOnce(conflict)
        .mockResolvedValueOnce({ queued_message: queuedMessage() });
      const { runtime } = createRuntime(null);
      runtime.draft.value = 'racing follow-up';

      await runtime.sendMessage();

      expect(apiMocks.post).toHaveBeenNthCalledWith(
        1,
        '/api/bff/chat-generation/12/send',
        { content: 'racing follow-up' }
      );
      expect(apiMocks.post).toHaveBeenNthCalledWith(
        2,
        '/api/bff/chat-generation/12/queue',
        { content: 'racing follow-up' }
      );
      expect(runtime.draft.value).toBe('');
    }
  );

  it('keeps a new draft when the server appends messages to the branch', async () => {
    const { runtime, branch } = createRuntime(null);
    runtime.draft.value = 'keep this';

    branch.value = [
      { id: 1, role: 'user', status: 'done', created_at: '2026-07-27T10:00:00Z' },
      { id: 2, role: 'assistant', status: 'done', created_at: '2026-07-27T10:00:01Z' },
    ];
    await nextTick();

    expect(runtime.draft.value).toBe('keep this');
  });

  it('hydrates queue updates returned by generation polling', async () => {
    apiMocks.get.mockResolvedValueOnce({
      ...completedPoll(31),
      queued_messages: [queuedMessage()],
    });
    const { runtime, onQueuedMessagesUpdated } = createRuntime(31);

    await runtime.startPolling(31);

    expect(onQueuedMessagesUpdated).toHaveBeenCalledWith([queuedMessage()]);
  });

  it('discovers and polls the next server-created generation', async () => {
    apiMocks.get
      .mockResolvedValueOnce({
        ...completedPoll(31),
        active_generation_message_id: 32,
      })
      .mockResolvedValueOnce(completedPoll(32));
    const { runtime } = createRuntime(31);

    await runtime.startPolling(31);
    await vi.waitFor(() => {
      expect(apiMocks.get).toHaveBeenCalledWith(
        '/api/bff/chat-messages/32/poll',
        expect.objectContaining({ showErrorBanner: false })
      );
    });
  });

  it('hides steering when the active configuration does not support it', () => {
    const { runtime } = createRuntime(31, false);
    runtime.draft.value = 'stop';

    expect(runtime.canSteerGeneration.value).toBe(false);
  });

  it('restores a focused composer covered by the keyboard while polling', async () => {
    const scroller = { scrollHeight: 2_024, clientHeight: 800, scrollTop: 1_200 };
    Object.defineProperty(document, 'scrollingElement', {
      configurable: true,
      value: scroller,
    });
    vi.stubGlobal('visualViewport', { pageTop: 1_200, offsetTop: 0, height: 500 });
    vi.stubGlobal(
      'requestAnimationFrame',
      vi.fn((callback: FrameRequestCallback) => {
        callback(0);
        return 1;
      })
    );
    const scrollTo = vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
    const composer = document.createElement('div');
    composer.className = 'chat-composer';
    const textarea = document.createElement('textarea');
    vi.spyOn(textarea, 'getBoundingClientRect').mockReturnValue({
      top: 630,
      bottom: 760,
      left: 0,
      right: 100,
      width: 100,
      height: 130,
      x: 0,
      y: 630,
      toJSON: () => ({}),
    });
    const scrollIntoView = vi.fn();
    composer.scrollIntoView = scrollIntoView;
    composer.append(textarea);
    document.body.append(composer);
    textarea.focus();
    apiMocks.get.mockResolvedValueOnce(completedPoll(31));
    const { runtime } = createRuntime(31, true, true);

    await runtime.startPolling(31);
    await vi.waitFor(() => expect(scrollIntoView).toHaveBeenCalledTimes(2));

    expect(scrollIntoView).toHaveBeenCalledWith({
      behavior: 'auto',
      block: 'nearest',
      inline: 'nearest',
    });
    expect(document.activeElement).toBe(textarea);
    expect(scrollTo).not.toHaveBeenCalled();
  });

  it('does not resume autoscroll after the visual viewport moves away from the bottom', async () => {
    const scroller = { scrollHeight: 2_000, clientHeight: 800, scrollTop: 1_200 };
    Object.defineProperty(document, 'scrollingElement', {
      configurable: true,
      value: scroller,
    });
    vi.stubGlobal('visualViewport', { pageTop: 1_350, height: 500 });
    const requestAnimationFrame = vi.fn((callback: FrameRequestCallback) => {
      callback(0);
      return 1;
    });
    vi.stubGlobal('requestAnimationFrame', requestAnimationFrame);
    const scrollTo = vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
    apiMocks.get.mockResolvedValueOnce(completedPoll(31));
    const { runtime } = createRuntime(31, true, true);

    await runtime.startPolling(31);
    await nextTick();
    await Promise.resolve();

    expect(scrollTo).not.toHaveBeenCalled();
    expect(requestAnimationFrame).not.toHaveBeenCalled();
  });

  it('keeps the layout viewport at the bottom when visualViewport is available without composer focus', async () => {
    const scroller = { scrollHeight: 2_000, clientHeight: 800, scrollTop: 1_200 };
    Object.defineProperty(document, 'scrollingElement', {
      configurable: true,
      value: scroller,
    });
    vi.stubGlobal('visualViewport', { pageTop: 1_500, offsetTop: 0, height: 500 });
    vi.stubGlobal(
      'requestAnimationFrame',
      vi.fn((callback: FrameRequestCallback) => {
        callback(0);
        return 1;
      })
    );
    const scrollTo = vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
    apiMocks.get.mockResolvedValueOnce(completedPoll(31));
    const { runtime } = createRuntime(31, true, true);

    await runtime.startPolling(31);
    await vi.waitFor(() => expect(scrollTo).toHaveBeenCalledTimes(2));

    expect(scrollTo).toHaveBeenCalledWith({ top: 1_200, left: 0, behavior: 'auto' });
  });

  it('keeps the layout viewport at the bottom when visualViewport is unavailable', async () => {
    const scroller = { scrollHeight: 2_000, clientHeight: 800, scrollTop: 1_200 };
    Object.defineProperty(document, 'scrollingElement', {
      configurable: true,
      value: scroller,
    });
    vi.stubGlobal('visualViewport', undefined);
    vi.stubGlobal(
      'requestAnimationFrame',
      vi.fn((callback: FrameRequestCallback) => {
        callback(0);
        return 1;
      })
    );
    const scrollTo = vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
    apiMocks.get.mockResolvedValueOnce(completedPoll(31));
    const { runtime } = createRuntime(31, true, true);

    await runtime.startPolling(31);
    await vi.waitFor(() => expect(scrollTo).toHaveBeenCalledTimes(2));

    expect(scrollTo).toHaveBeenCalledWith({ top: 1_200, left: 0, behavior: 'auto' });
  });
});
