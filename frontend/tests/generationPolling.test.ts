import { computed, effectScope, nextTick, ref } from 'vue';

const mocks = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn(), publish: vi.fn() }));
vi.mock('@/api/client', () => ({
  api: mocks,
  getApiErrorMessage: (_: unknown, fallback: string) => fallback,
  isHttpError: () => false,
}));
vi.mock('@/features/chat/chatEvents', () => ({ publishChatChange: mocks.publish }));

import {
  generationPollDelay,
  mergeRuntimePollContent,
} from '@/features/chat/model/generationPolling';
import { useChatComposerRuntime } from '@/features/chat/model/useChatComposerRuntime';
import type { PollResponse } from '@/features/chat/model/chatViewModel.shared';
import type { ChatBranchMessage } from '@/types/api';

const initial: PollResponse = {
  message_id: 31,
  runtime: true,
  status: 'generating',
  phase: 'streaming',
  revision: 'r1',
  content_revision: 'c1',
  content: { items: [], parts: [{ content_id: 1, sequence: 1, text: 'visible' }], media: [] },
};
const cleanups: (() => void)[] = [];

function setupRuntime(onGenerationSettled?: (id: number, status: string) => Promise<void>) {
  const chatId = ref(12);
  const branch = ref<ChatBranchMessage[]>([{ id: 31, role: 'assistant', status: 'generating' }]);
  const selection = ref<string | null>(null);
  const detailRevision = ref<string | undefined>();
  const applyWorkingPoll = vi.fn();
  const activeGenerationId = ref<number | null>(31);
  const onQueuedMessagesUpdated = vi.fn();
  const scope = effectScope();
  const runtime = scope.run(() =>
    useChatComposerRuntime({
      chatId: computed(() => chatId.value),
      branch,
      readOnly: computed(() => false),
      loadError: ref(''),
      fileUploadPolicy: computed(() => ({
        allowsFiles: true,
        imagesOnly: false,
        maxFileSizeBytes: 1024,
        accept: '',
      })),
      waitForConfigSync: async () => true,
      activeGenerationId,
      onGenerationSettled,
      onQueuedMessagesUpdated,
      cancelingGenerationId: ref(null),
      autoScrollEnabled: computed(() => false),
      scrollToLastMessage: vi.fn(),
      getOpenWorkingPollRequest: () => selection.value,
      getOpenWorkingPollRevision: () => detailRevision.value,
      applyWorkingPoll,
    })
  )!;
  cleanups.push(() => {
    runtime.stopPolling();
    scope.stop();
  });
  return { runtime, branch, chatId, selection, detailRevision, applyWorkingPoll, activeGenerationId, onQueuedMessagesUpdated };
}

describe('revision-aware generation polling', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    mocks.get.mockReset();
    mocks.post.mockReset();
    mocks.publish.mockReset();
    window.localStorage.clear();
  });
  afterEach(() => {
    cleanups.splice(0).forEach((cleanup) => cleanup());
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it('uses streaming and waiting intervals, including bounded server hints', () => {
    expect(generationPollDelay(initial)).toBe(500);
    for (const phase of ['waiting_tools', 'persisting', 'backoff', 'initializing']) {
      expect(generationPollDelay({ ...initial, phase })).toBe(1750);
    }
    expect(generationPollDelay({ ...initial, availability: 'busy' })).toBe(1750);
    expect(generationPollDelay({ ...initial, poll_after_ms: 0 })).toBe(500);
    expect(generationPollDelay({ ...initial, poll_after_ms: 99_999 })).toBe(2000);
  });

  it('replaces only streaming content and keeps completed steps in order', () => {
    const completed = { content_id: 1, sequence: 1, step_sequence: 1, text: 'completed' };
    const before = {
      items: [],
      parts: [completed, { content_id: -1, sequence: 1, step_sequence: 2, text: 'first' }],
      media: [],
    };
    const runtime = {
      items: [],
      parts: [{ content_id: -1, sequence: 1, step_sequence: 2, text: 'second' }],
      media: [],
    };
    const changed = mergeRuntimePollContent(before, {
      ...initial,
      content: undefined,
      runtime_content: runtime,
      runtime_step_sequence: 2,
    });
    expect(changed?.parts.map((part) => part.text)).toEqual(['completed', 'second']);
    expect(changed?.parts[0]).toBe(completed);
    expect(mergeRuntimePollContent(changed, { ...initial, content: undefined })).toBe(changed);
    expect(
      mergeRuntimePollContent(changed, {
        ...initial,
        content: undefined,
        runtime_content: { items: [], parts: [], media: [] },
        runtime_step_sequence: 2,
      })
    ).toBe(changed);
  });

  it('sends revisions, preserves omitted content and accepts 204 without failing', async () => {
    mocks.get
      .mockResolvedValueOnce(initial)
      .mockResolvedValueOnce({
        ...initial,
        content: undefined,
        revision: 'r2',
        availability: 'busy',
        phase: 'persisting',
      })
      .mockResolvedValue(undefined);
    const { runtime, branch } = setupRuntime();
    await runtime.startPolling(31);
    const content = branch.value[0].content;
    await vi.advanceTimersByTimeAsync(500);
    expect(mocks.get.mock.calls[1][0]).toContain('revision=r1');
    expect(mocks.get.mock.calls[1][0]).toContain('content_revision=c1');
    expect(branch.value[0].content).toEqual(content);
    expect(branch.value[0].status).toBe('generating');
    await vi.advanceTimersByTimeAsync(1749);
    expect(mocks.get).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(mocks.get).toHaveBeenCalledTimes(3);
    expect(runtime.generationPollReconnecting.value).toBe(false);
    expect(branch.value[0].content).toEqual(content);
    await vi.advanceTimersByTimeAsync(1750);
    expect(mocks.get).toHaveBeenCalledTimes(4);
  });

  it('resynchronizes after a full branch reload and on resume', async () => {
    mocks.get.mockResolvedValue(initial);
    const { runtime, branch } = setupRuntime();
    await runtime.startPolling(31);
    branch.value = [{ id: 31, role: 'assistant', status: 'generating' }];
    await vi.advanceTimersByTimeAsync(500);
    expect(mocks.get.mock.calls[1][0]).toBe('/api/bff/chat-messages/31/poll');
    expect(branch.value[0].content).toEqual(initial.content);
    await runtime.startPolling(31);
    expect(mocks.get.mock.calls[2][0]).toBe('/api/bff/chat-messages/31/poll');
  });

  it('discards responses from the previous route or replaced branch', async () => {
    let resolve!: (value: PollResponse) => void;
    mocks.get.mockReturnValueOnce(
      new Promise<PollResponse>((done) => {
        resolve = done;
      })
    );
    const { runtime, branch, chatId } = setupRuntime();
    const pending = runtime.startPolling(31);
    chatId.value = 13;
    branch.value = [{ id: 99, role: 'assistant', status: 'generating' }];
    resolve(initial);
    await pending;
    runtime.stopPolling();
    await nextTick();
    runtime.stopPolling();
    expect(branch.value[0].id).toBe(99);
    expect(branch.value[0].content).toBeUndefined();
  });

  it.each([false, true])(
    'discards a terminal continuation after a new poll starts (route change: %s)',
    async (changeRoute) => {
      let entered!: () => void;
      let release!: () => void;
      const callbackEntered = new Promise<void>((resolve) => { entered = resolve; });
      const callbackPending = new Promise<void>((resolve) => { release = resolve; });
      const settled = vi.fn(async () => {
        entered();
        await callbackPending;
      });
      mocks.get
        .mockResolvedValueOnce({ ...initial, status: 'done', active_generation_message_id: 32 })
        .mockResolvedValue({ ...initial, message_id: 99, content: undefined });
      const { runtime, chatId, branch, activeGenerationId, onQueuedMessagesUpdated } =
        setupRuntime(settled);
      const oldPoll = runtime.startPolling(31);
      await callbackEntered;
      if (changeRoute) chatId.value = 13;
      branch.value = [{ id: 99, role: 'assistant', status: 'generating' }];
      await runtime.startPolling(99);
      await nextTick();
      mocks.publish.mockClear();
      onQueuedMessagesUpdated.mockClear();
      release();
      await oldPoll;
      expect(activeGenerationId.value).toBe(99);
      expect(branch.value[0].id).toBe(99);
      expect(onQueuedMessagesUpdated).not.toHaveBeenCalled();
      expect(mocks.publish).not.toHaveBeenCalled();
      expect(mocks.get.mock.calls.some(([url]) => url.includes('/32/poll'))).toBe(false);
      await vi.advanceTimersByTimeAsync(500);
      expect(mocks.get.mock.calls.at(-1)?.[0]).toContain('/99/poll');
      expect(activeGenerationId.value).toBe(99);
    }
  );

  it('sends working revisions and never applies a late response to a new selection', async () => {
    let resolve!: (value: PollResponse) => void;
    mocks.get.mockReturnValueOnce(
      new Promise<PollResponse>((done) => {
        resolve = done;
      })
    );
    const { runtime, selection, detailRevision, applyWorkingPoll } = setupRuntime();
    selection.value = 'latest';
    detailRevision.value = 'detail1';
    const pending = runtime.startPolling(31);
    expect(mocks.get.mock.calls[0][0]).toContain('working_revision=detail1');
    selection.value = '5';
    resolve({ ...initial, working_open: { selected_step_id: 9, revision: 'detail2' } });
    await pending;
    expect(applyWorkingPoll).not.toHaveBeenCalled();
  });

  it('backs off transport failures without marking the generation failed and resets after success', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    mocks.get
      .mockRejectedValueOnce(new Error('network'))
      .mockRejectedValueOnce(new Error('network'))
      .mockResolvedValue(initial);
    const { runtime, branch } = setupRuntime();
    await runtime.startPolling(31);
    expect(runtime.generationPollReconnecting.value).toBe(true);
    await vi.advanceTimersByTimeAsync(1500);
    expect(mocks.get).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(2999);
    expect(mocks.get).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(mocks.get).toHaveBeenCalledTimes(3);
    expect(runtime.generationPollReconnecting.value).toBe(false);
    expect(branch.value[0].status).toBe('generating');
    await vi.advanceTimersByTimeAsync(500);
    expect(mocks.get).toHaveBeenCalledTimes(4);
  });
});
