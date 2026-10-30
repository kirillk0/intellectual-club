import { computed, nextTick, ref } from 'vue';
import { flushPromises } from '@vue/test-utils';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  isHttpError: vi.fn(),
  post: vi.fn(),
  put: vi.fn(),
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
  autoScrollEnabled = false,
  initialQueue: ChatQueuedMessage[] = [],
  onGenerationSettled?: () => Promise<void> | void,
  syncDraft = false
) => {
  const branch = ref<ChatBranchMessage[]>(
    activeMessageId
      ? [{ id: activeMessageId, role: 'assistant', status: 'generating', llm_configuration_id: 27 }]
      : []
  );
  const activeGenerationId = ref(activeMessageId);
  const loadError = ref('');
  const queuedMessages = ref(initialQueue);
  const chatId = ref(12);
  const waitForConfigSync = vi.fn(async () => true);
  const onQueuedMessageCreated = vi.fn();
  const onQueuedMessagesUpdated = vi.fn();

  const runtime = useChatComposerRuntime({
    ...(syncDraft ? { draftUserId: computed(() => 1), draftOwned: computed(() => true) } : {}),
    chatId: computed(() => chatId.value),
    branch,
    readOnly: computed(() => false),
    loadError,
    fileUploadPolicy: computed(() => ({
      allowsFiles: true,
      imagesOnly: false,
      maxFileSizeBytes: 1024,
      accept: '',
    })),
    waitForConfigSync,
    activeGenerationId,
    cancelingGenerationId: ref(null),
    queuedMessages,
    autoScrollEnabled: computed(() => autoScrollEnabled),
    scrollToLastMessage: vi.fn(),
    onQueuedMessageCreated,
    onQueuedMessagesUpdated,
    onGenerationSettled,
  });

  return {
    runtime,
    chatId,
    waitForConfigSync,
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
  let viewportWidth = 390;

  beforeEach(() => {
    viewportWidth = 390;
    vi.stubGlobal('matchMedia', vi.fn(() => ({ matches: viewportWidth <= 900 })));
    window.localStorage.clear();
    apiMocks.get.mockReset();
    apiMocks.isHttpError.mockReset().mockReturnValue(false);
    apiMocks.post.mockReset();
    apiMocks.put.mockReset();
  });

  afterEach(() => {
    document.body.innerHTML = '';
    Reflect.deleteProperty(document, 'scrollingElement');
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('sends the persisted draft revision and clears only the accepted server snapshot', async () => {
    let serverDraft = { text: '', revision: 0, updated_at: null };
    apiMocks.get.mockImplementation(async () => ({ draft: { ...serverDraft } }));
    apiMocks.put.mockImplementation(async (_url, body) => {
      serverDraft = { ...serverDraft, text: body.text, revision: serverDraft.revision + 1 };
      return { draft: { ...serverDraft } };
    });
    const { runtime } = createRuntime(null, false, [], undefined, true);
    await flushPromises();
    runtime.draft.value = 'send this';
    apiMocks.post.mockImplementation(async (_url, body) => {
      expect(body.draft_revision).toBe(1);
      serverDraft = { ...serverDraft, text: '', revision: 2 };
      return { branch: [], generation: null };
    });
    await runtime.sendMessage();
    await flushPromises();
    expect(apiMocks.put).toHaveBeenCalledWith('/api/bff/chat-drafts/12',
      { text: 'send this', expected_revision: 0 }, expect.any(Object));
    expect(runtime.draft.value).toBe('');
    expect(runtime.draftSyncState.value).toBe('idle');
    expect(JSON.parse(localStorage.getItem('ic.draft.user.1.chat.12')!).base.revision).toBe(2);
    await runtime.dispose();
  });

  it('keeps text typed during sending and saves it against the consumed revision', async () => {
    let serverDraft = { text: '', revision: 0, updated_at: null };
    apiMocks.get.mockImplementation(async () => ({ draft: { ...serverDraft } }));
    apiMocks.put.mockImplementation(async (_url, body) => {
      expect(body.expected_revision).toBe(serverDraft.revision);
      serverDraft = { ...serverDraft, text: body.text, revision: serverDraft.revision + 1 };
      return { draft: { ...serverDraft } };
    });
    const { runtime } = createRuntime(null, false, [], undefined, true);
    await flushPromises(); runtime.draft.value = 'submitted';
    let acknowledge!: (value: unknown) => void;
    apiMocks.post.mockReturnValue(new Promise((resolve) => { acknowledge = resolve; }));
    const sending = runtime.sendMessage(); await flushPromises();
    runtime.draft.value = 'next thought';
    serverDraft = { ...serverDraft, text: '', revision: 2 };
    acknowledge({ branch: [], generation: null });
    await sending; await flushPromises();
    expect(runtime.draft.value).toBe('next thought');
    expect(serverDraft.text).toBe('next thought');
    expect(runtime.draftSyncState.value).toBe('saved');
    await runtime.dispose();
  });

  it('keeps the draft status silent during routine saves and reports a failed save', async () => {
    vi.useFakeTimers();
    try {
      apiMocks.get.mockResolvedValue({ draft: { text: '', revision: 0, updated_at: null } });
      apiMocks.put.mockRejectedValueOnce(new Error('network'))
        .mockResolvedValue({ draft: { text: 'typed', revision: 1, updated_at: null } });
      const { runtime } = createRuntime(null, false, [], undefined, true);
      await flushPromises();
      runtime.draft.value = 'typed';
      expect(runtime.draftStatusLabel.value).toBe('');
      await vi.advanceTimersByTimeAsync(1_000);
      expect(runtime.draftProblem.value).toBe('error');
      expect(runtime.draftStatusLabel.value).toBe('Draft could not be synced');
      await vi.advanceTimersByTimeAsync(2_000);
      expect(runtime.draftSyncState.value).toBe('saved');
      expect(runtime.draftStatusLabel.value).toBe('');
      await runtime.dispose();
    } finally {
      vi.useRealTimers();
    }
  });

  it('starts attachment uploads with the configuration the message is composed for', async () => {
    const { runtime } = createRuntime(null);
    apiMocks.post.mockResolvedValue({
      upload: {
        upload_id: 'upload-for-branch',
        filename: 'note.txt',
        mime_type: 'text/plain',
        size_bytes: 4,
        uploaded_bytes: 4,
        chunk_size_bytes: 1024,
        status: 'uploaded',
        expires_at: '2026-10-22T00:00:00Z',
      },
    });
    const files = ref([pendingFile()]);

    await expect(
      runtime.ensurePendingFilesUploaded(files, undefined, { llmConfigurationId: 8 })
    ).resolves.toEqual(['upload-for-branch']);

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-uploads/12', {
      filename: 'note.txt',
      mime_type: 'text/plain',
      size_bytes: 4,
      llm_configuration_id: 8,
    });
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
      '/api/bff/chat-messages/31/poll?poll_protocol=cursor',
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

  it('preserves draft and pending files on a refused steer while quarantined instructions remain visible', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => undefined);
    const rejected = { ...queuedSteer(), status: 'blocked', blocked_reason: 'steering_failed' } satisfies ChatQueuedMessage;
    const error = { status: 422, bodyJson: { code: 'steering_failed' } };
    apiMocks.isHttpError.mockImplementation((value) => value === error);
    apiMocks.post.mockRejectedValueOnce(error);
    const { runtime, queuedMessages, onQueuedMessageCreated } = createRuntime(31, false, [rejected]);
    const file = pendingFile();
    runtime.pendingFiles.value = [file];
    runtime.draft.value = 'Keep this correction';

    await runtime.steerGeneration();

    expect(runtime.draft.value).toBe('Keep this correction');
    expect(runtime.pendingFiles.value).toEqual([file]);
    expect(queuedMessages.value).toEqual([rejected]);
    expect(onQueuedMessageCreated).not.toHaveBeenCalled();
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
    const { runtime } = createRuntime(null, false, [queuedMessage()]);
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
        { content: 'racing follow-up', parent_id: null }
      );
      expect(apiMocks.post).toHaveBeenNthCalledWith(
        2,
        '/api/bff/chat-generation/12/queue',
        { content: 'racing follow-up' }
      );
      expect(runtime.draft.value).toBe('');
    }
  );

  it.each(['send', 'continue'] as const)('anchors %s explicitly to the visible leaf', async (action) => {
    const { runtime, branch } = createRuntime(null);
    branch.value = [{ id: 20, role: 'assistant', status: 'done' }];
    apiMocks.post.mockResolvedValue({ branch: branch.value, generation: null });
    if (action === 'send') runtime.draft.value = 'next';

    await (action === 'send' ? runtime.sendMessage() : runtime.continueGeneration());

    expect(apiMocks.post).toHaveBeenCalledWith(
      `/api/bff/chat-generation/12/${action === 'send' ? 'send' : 'generate'}`,
      action === 'send' ? { content: 'next', parent_id: 20 } : { parent_id: 20 }
    );
    await runtime.dispose();
  });

  it('continues an empty visible branch with an explicit null parent', async () => {
    const { runtime } = createRuntime(null);
    apiMocks.post.mockResolvedValue({ branch: [], generation: null });
    await runtime.continueGeneration();
    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-generation/12/generate', { parent_id: null });
    await runtime.dispose();
  });

  it.each([
    ['send', false], ['continue', false], ['send', true], ['continue', true],
  ] as const)('ignores late %s responses after navigation (new chat: %s)', async (action, changeChat) => {
    let resolve!: (value: unknown) => void;
    apiMocks.post.mockReturnValue(new Promise((done) => { resolve = done; }));
    const { runtime, branch, chatId, activeGenerationId } = createRuntime(null);
    branch.value = [{ id: 20, role: 'assistant', status: 'done' }];
    if (action === 'send') runtime.draft.value = 'next';
    const pending = action === 'send' ? runtime.sendMessage() : runtime.continueGeneration();
    await nextTick();
    expect(apiMocks.post).toHaveBeenCalledTimes(1);

    if (changeChat) chatId.value = 13;
    branch.value = [{ id: 99, role: 'assistant', status: 'done' }];
    runtime.draft.value = 'new branch draft';
    resolve({ branch: [{ id: 21, role: 'assistant', status: 'generating' }], generation: { message_id: 21 } });
    await pending;

    expect(branch.value.map((message) => message.id)).toEqual([99]);
    expect(activeGenerationId.value).toBeNull();
    expect(apiMocks.get).not.toHaveBeenCalled();
    expect(runtime.draft.value).toBe('new branch draft');
    await runtime.dispose();
  });

  it.each(['send', 'continue'] as const)('does not %s on a different branch after configuration sync', async (action) => {
    let resolve!: (value: boolean) => void;
    const { runtime, branch, waitForConfigSync } = createRuntime(null);
    waitForConfigSync.mockReturnValue(new Promise((done) => { resolve = done; }));
    if (action === 'send') runtime.draft.value = 'next';
    const pending = action === 'send' ? runtime.sendMessage() : runtime.continueGeneration();
    branch.value = [{ id: 99, role: 'assistant', status: 'done' }];
    resolve(true);
    await pending;
    expect(apiMocks.post).not.toHaveBeenCalled();
    await runtime.dispose();
  });

  it.each([
    ['send', 'config'], ['continue', 'config'], ['send', 'post'], ['continue', 'post'],
  ] as const)('accepts %s after a same-branch reload during %s', async (action, stage) => {
    const { runtime, branch, waitForConfigSync } = createRuntime(null);
    branch.value = [{ id: 20, role: 'assistant', status: 'done' }];
    let resolveConfig!: (value: boolean) => void;
    let resolvePost!: (value: unknown) => void;
    waitForConfigSync.mockReturnValue(new Promise((resolve) => { resolveConfig = resolve; }));
    apiMocks.post.mockReturnValue(new Promise((resolve) => { resolvePost = resolve; }));
    apiMocks.get.mockResolvedValue(completedPoll(21));
    if (action === 'send') runtime.draft.value = 'next';
    const pending = action === 'send' ? runtime.sendMessage() : runtime.continueGeneration();
    if (stage === 'post') {
      resolveConfig(true);
      await nextTick();
      expect(apiMocks.post).toHaveBeenCalledTimes(1);
    }
    branch.value = branch.value.map((message) => ({ ...message, token_count: 100 }));
    resolveConfig(true);
    resolvePost({ branch: [{ id: 21, role: 'assistant', status: 'generating' }], generation: { message_id: 21 } });
    await pending;

    expect(apiMocks.post).toHaveBeenCalledWith(
      `/api/bff/chat-generation/12/${action === 'send' ? 'send' : 'generate'}`,
      action === 'send' ? { content: 'next', parent_id: 20 } : { parent_id: 20 }
    );
    expect(branch.value.map((message) => message.id)).toEqual([21]);
    expect(apiMocks.get).toHaveBeenCalledTimes(1);
    expect(runtime.draft.value).toBe('');
    await runtime.dispose();
  });

  it('sends uploaded attachments after a same-branch reload during upload', async () => {
    const { runtime, branch } = createRuntime(null);
    branch.value = [{ id: 20, role: 'assistant', status: 'done' }];
    runtime.pendingFiles.value = [pendingFile()];
    let resolveUpload!: (value: unknown) => void;
    apiMocks.post.mockReturnValueOnce(new Promise((resolve) => { resolveUpload = resolve; }))
      .mockResolvedValueOnce({ branch: [{ id: 21, role: 'user', status: 'done' }], generation: null });
    const pending = runtime.sendMessage();
    await nextTick();
    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-uploads/12', expect.anything());
    branch.value = branch.value.map((message) => ({ ...message, token_count: 100 }));
    resolveUpload({ upload: {
      upload_id: 'uploaded', status: 'uploaded', uploaded_bytes: 4, chunk_size_bytes: 1024,
    } });
    await pending;

    expect(apiMocks.post).toHaveBeenLastCalledWith('/api/bff/chat-generation/12/send', {
      content: '', upload_ids: ['uploaded'], parent_id: 20,
    });
    expect(branch.value.map((message) => message.id)).toEqual([21]);
    expect(runtime.pendingFiles.value).toEqual([]);
    await runtime.dispose();
  });

  it.each([
    ['reload', false], ['reload', true], ['branch', false], ['branch', true],
    ['extended', false], ['extended', true], ['chat', false], ['chat', true],
  ] as const)('clears only the accepted send snapshot after %s (new text: %s)', async (change, newText) => {
    const { runtime, branch, chatId, activeGenerationId } = createRuntime(null);
    branch.value = [{ id: 20, role: 'assistant', status: 'done' }];
    runtime.draft.value = 'sent';
    runtime.pendingFiles.value = [uploadedPendingFile('submitted')];
    await nextTick();
    let acknowledge!: (value: unknown) => void;
    apiMocks.post.mockReturnValue(new Promise((resolve) => { acknowledge = resolve; }));
    const pending = runtime.sendMessage();
    await vi.waitFor(() => expect(apiMocks.post).toHaveBeenCalledTimes(1));
    if (change === 'reload') branch.value = branch.value.map((message) => ({ ...message }));
    else if (change === 'extended') branch.value = [...branch.value, { id: 99, role: 'user', status: 'done' }];
    else {
      if (change === 'chat') chatId.value = 13;
      branch.value = [{ id: 99, role: 'assistant', status: 'done' }];
    }
    await nextTick();
    runtime.draft.value = newText ? 'new draft' : 'sent';
    runtime.pendingFiles.value = [...runtime.pendingFiles.value, uploadedPendingFile('later')];
    await nextTick();
    const visibleBranch = branch.value;
    acknowledge({ branch: [{ id: 21, role: 'assistant', status: 'done' }], generation: null });
    await pending;
    await nextTick();

    expect(runtime.draft.value).toBe(newText ? 'new draft' : change === 'chat' ? 'sent' : '');
    expect(runtime.pendingFiles.value.map((file) => file.id)).toEqual(
      change === 'chat' ? ['submitted', 'later'] : ['later']
    );
    if (change === 'reload') expect(branch.value.map((message) => message.id)).toEqual([21]);
    else expect(branch.value).toBe(visibleBranch);
    expect(activeGenerationId.value).toBeNull();
    expect(apiMocks.get).not.toHaveBeenCalled();
    const stored = window.localStorage.getItem('ic.draft.chat.composer.12');
    if (newText && change !== 'chat') expect(JSON.parse(stored!).text).toBe('new draft');
    else expect(stored).toBeNull();
    // Avoid aborting already uploaded test fixtures during cleanup.
    runtime.pendingFiles.value = [];
    await runtime.dispose();
  });

  it('preserves an edited stored draft in the original chat after a late send acknowledgement', async () => {
    const { runtime, chatId } = createRuntime(null);
    runtime.draft.value = 'sent';
    await nextTick();
    let acknowledge!: (value: unknown) => void;
    apiMocks.post.mockReturnValue(new Promise((resolve) => { acknowledge = resolve; }));
    const pending = runtime.sendMessage();
    await nextTick();
    expect(apiMocks.post).toHaveBeenCalledTimes(1);
    chatId.value = 13;
    await nextTick();
    runtime.draft.value = 'other chat';
    const storageKey = 'ic.draft.chat.composer.12';
    const stored = JSON.parse(window.localStorage.getItem(storageKey)!);
    window.localStorage.setItem(storageKey, JSON.stringify({ ...stored, text: 'edited elsewhere' }));
    acknowledge({ branch: [], generation: null });
    await pending;

    expect(runtime.draft.value).toBe('other chat');
    expect(JSON.parse(window.localStorage.getItem(storageKey)!).text).toBe('edited elsewhere');
    await runtime.dispose();
  });

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
    const { runtime, branch } = createRuntime(31, false, [], () => {
      branch.value = [...branch.value, { id: 32, role: 'assistant', status: 'generating' }];
    });

    await runtime.startPolling(31);
    await vi.waitFor(() => {
      expect(apiMocks.get).toHaveBeenCalledWith(
        '/api/bff/chat-messages/32/poll?poll_protocol=cursor',
        expect.objectContaining({ showErrorBanner: false })
      );
    });
  });

  it('allows steering without configuration capability metadata', () => {
    const { runtime } = createRuntime(31);
    runtime.draft.value = 'stop';

    expect(runtime.canSteerGeneration.value).toBe(true);
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
    const { runtime } = createRuntime(31, true);

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
    const { runtime } = createRuntime(31, true);

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
    const { runtime } = createRuntime(31, true);

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
    const { runtime } = createRuntime(31, true);

    await runtime.startPolling(31);
    await vi.waitFor(() => expect(scrollTo).toHaveBeenCalledTimes(2));

    expect(scrollTo).toHaveBeenCalledWith({ top: 1_200, left: 0, behavior: 'auto' });
  });

  describe('responsive autoscroll', () => {
    const setupPage = (width: number, distance = 0, focused = true) => {
      viewportWidth = width;
      const scroller = {
        scrollHeight: 2_000,
        clientHeight: 800,
        scrollTop: 1_200 - distance,
        scrollIntoView: vi.fn(),
      };
      Object.defineProperty(document, 'scrollingElement', { configurable: true, value: scroller });
      vi.stubGlobal('visualViewport', { pageTop: scroller.scrollTop, height: 800 });
      const requestAnimationFrame = vi.fn((callback: FrameRequestCallback) => {
        callback(0);
        return 1;
      });
      vi.stubGlobal('requestAnimationFrame', requestAnimationFrame);
      const scrollTo = vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
      const composer = document.createElement('div');
      composer.className = 'chat-composer';
      composer.scrollIntoView = vi.fn();
      const textarea = document.createElement('textarea');
      vi.spyOn(textarea, 'getBoundingClientRect').mockReturnValue(new DOMRect(0, 630 + distance, 100, 130));
      composer.append(textarea);
      document.body.append(composer);
      if (focused) textarea.focus();
      apiMocks.get.mockResolvedValue(completedPoll(31));
      return { scroller, composer, textarea, scrollTo, requestAnimationFrame };
    };

    it.each([390, 900, 901, 1280])('uses legacy focus following only at narrow widths (%i px)', async (width) => {
      const { scroller, composer, textarea, scrollTo, requestAnimationFrame } = setupPage(width, 100);
      const { runtime } = createRuntime(31, true);

      await runtime.startPolling(31);
      if (width <= 900) {
        await vi.waitFor(() => expect(composer.scrollIntoView).toHaveBeenCalledTimes(2));
        expect(composer.scrollIntoView).toHaveBeenCalledWith({
          behavior: 'auto', block: 'nearest', inline: 'nearest',
        });
      } else {
        await nextTick();
        expect(composer.scrollIntoView).not.toHaveBeenCalled();
        expect(requestAnimationFrame).not.toHaveBeenCalled();
      }
      expect(document.activeElement).toBe(textarea);
      expect(scroller.scrollIntoView).not.toHaveBeenCalled();
      expect(scrollTo).not.toHaveBeenCalled();
    });

    it.each([390, 900, 901, 1280])('keeps following at the bottom without composer focus (%i px)', async (width) => {
      const { scroller, composer, scrollTo } = setupPage(width, 0, false);
      const { runtime } = createRuntime(31, true);

      await runtime.startPolling(31);
      const scroll = width <= 900 ? scrollTo : scroller.scrollIntoView;
      await vi.waitFor(() => expect(scroll).toHaveBeenCalledTimes(2));
      if (width <= 900) {
        expect(scrollTo).toHaveBeenCalledWith({ top: 1_200, left: 0, behavior: 'auto' });
        expect(scroller.scrollIntoView).not.toHaveBeenCalled();
      } else {
        expect(scroller.scrollIntoView).toHaveBeenCalledWith({
          behavior: 'auto', block: 'end', inline: 'nearest',
        });
        expect(scrollTo).not.toHaveBeenCalled();
      }
      expect(composer.scrollIntoView).not.toHaveBeenCalled();
    });

    it.each([
      { distance: 8, focused: true },
      { distance: 8, focused: false },
      { distance: 9, focused: true },
      { distance: 9, focused: false },
    ])('uses an 8 px tolerance on wide screens (distance: $distance, focus: $focused)', async ({ distance, focused }) => {
      const { scroller, composer, requestAnimationFrame } = setupPage(1280, distance, focused);
      const { runtime } = createRuntime(31, true);

      await runtime.startPolling(31);
      if (distance === 8) {
        await vi.waitFor(() => expect(scroller.scrollIntoView).toHaveBeenCalledTimes(2));
      } else {
        await nextTick();
        expect(scroller.scrollIntoView).not.toHaveBeenCalled();
        expect(requestAnimationFrame).not.toHaveBeenCalled();
      }
      expect(composer.scrollIntoView).not.toHaveBeenCalled();
    });

    it('switches behavior after resizing without recreating the chat', async () => {
      const { composer, scroller } = setupPage(390, 24);
      const { runtime } = createRuntime(31, true);
      apiMocks.get.mockResolvedValue({ ...completedPoll(31), status: 'generating' });

      await runtime.startPolling(31);
      await vi.waitFor(() => expect(composer.scrollIntoView).toHaveBeenCalledTimes(2));
      viewportWidth = 1280;
      await runtime.startPolling(31);
      await nextTick();
      expect(composer.scrollIntoView).toHaveBeenCalledTimes(2);
      expect(scroller.scrollIntoView).not.toHaveBeenCalled();
      viewportWidth = 390;
      await runtime.startPolling(31);
      await vi.waitFor(() => expect(composer.scrollIntoView).toHaveBeenCalledTimes(4));
      await runtime.dispose();
    });
  });
});
