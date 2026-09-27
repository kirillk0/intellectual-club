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
  selectRuntimeCursor,
  validRuntimeDelta,
  mergeRuntimePollContent,
  mergeRuntimeUsage,
  preserveStreamingMessageContent,
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

function streamingMessage(): ChatBranchMessage {
  const completed = { step_id: 100, step_sequence: 1, item_id: 101, item_sequence: 1, item_type: 'answer' };
  const steering = { step_id: 200, step_sequence: 2, item_id: -101, item_sequence: 1, item_type: 'steering' };
  const answer = { step_id: 200, step_sequence: 2, item_id: -102, item_sequence: 2, item_type: 'answer' };
  const artifact = { ...answer, item_id: -103, item_sequence: 3, item_type: 'artifact' };
  return {
    id: 31, role: 'assistant', status: 'generating',
    working: { step_count: 2, latest_step_id: 200, latest_step_sequence: 2,
      latest_step_status: 'waiting_provider', completed_step_duration_ms: 100 },
    content: {
      items: [completed, steering, answer, artifact],
      parts: [
        { ...completed, content_id: 1001, sequence: 1, text: 'Completed answer' },
        { ...steering, content_id: -21001, sequence: 1, text: 'Steering' },
        { ...answer, content_id: -22001, sequence: 1, text: 'Streaming answer' },
      ],
      media: [{ ...artifact, id: -23001, sequence: 1, kind: 'media', media: {
        external_id: 'file-1', filename: 'image.png', mime_type: 'image/png', size_bytes: 1,
        sha256: '', is_image: true,
      } }],
    },
  };
}

function persistedOnlyMessage(): ChatBranchMessage {
  const message = streamingMessage();
  message.bookmarked = true;
  message.content!.items = message.content!.items.slice(0, 2).map((item) => ({ ...item, item_id: Math.abs(item.item_id!) }));
  message.content!.parts = message.content!.parts.slice(0, 2).map((part) => ({
    ...part, item_id: Math.abs(part.item_id!), content_id: Math.abs(part.content_id),
  }));
  message.content!.parts[0]!.text = 'Edited completed answer';
  message.content!.media = [];
  return message;
}

describe('persisted branch reconciliation', () => {
  it('retains the whole live step without duplicating persisted steering or losing earlier edits', () => {
    const current = streamingMessage();
    const incoming = persistedOnlyMessage();
    const result = preserveStreamingMessageContent(current, incoming);
    expect(result.bookmarked).toBe(true);
    expect(result.working).toBe(incoming.working);
    expect(result.content!.parts.map((part) => part.text)).toEqual([
      'Edited completed answer', 'Steering', 'Streaming answer',
    ]);
    expect(result.content!.items.map((item) => item.item_id)).toEqual([101, -101, -102, -103]);
    expect(result.content!.media).toEqual(current.content!.media);
    expect(current.content!.parts[0]!.text).toBe('Completed answer');
    expect(incoming.content!.parts).toHaveLength(2);
  });

  it.each(['waiting_tools', 'done', 'canceled', 'error'])('accepts canonical step status %s even before message finalization', (status) => {
    const incoming = persistedOnlyMessage();
    incoming.working!.latest_step_status = status;
    expect(preserveStreamingMessageContent(streamingMessage(), incoming)).toBe(incoming);
  });

  it.each(['done', 'canceled', 'error'])('accepts terminal message status %s', (status) => {
    const incoming = persistedOnlyMessage();
    incoming.status = status;
    expect(preserveStreamingMessageContent(streamingMessage(), incoming)).toBe(incoming);
  });

  it('accepts persisted provider content even with pre-commit step metadata', () => {
    const incoming = streamingMessage();
    incoming.content!.items = incoming.content!.items.map((item) => ({ ...item, item_id: Math.abs(item.item_id!) }));
    incoming.content!.parts = incoming.content!.parts.map((part) => ({
      ...part, item_id: Math.abs(part.item_id!), content_id: Math.abs(part.content_id),
    }));
    incoming.content!.media = incoming.content!.media.map((item) => ({
      ...item, item_id: Math.abs(item.item_id!), id: Math.abs(item.id),
    }));
    expect(preserveStreamingMessageContent(streamingMessage(), incoming)).toBe(incoming);
  });

  it('does not resurrect runtime when retry reuses the sequence with a new step ID', () => {
    const incoming = persistedOnlyMessage();
    incoming.working!.latest_step_id = 201;
    expect(preserveStreamingMessageContent(streamingMessage(), incoming)).toBe(incoming);
  });

  it('does not overlay a successor, another message, or content without runtime IDs', () => {
    const current = streamingMessage();
    const incoming = persistedOnlyMessage();
    const successor = { ...incoming, working: { ...incoming.working!, latest_step_id: 300, latest_step_sequence: 3 } };
    expect(preserveStreamingMessageContent(current, successor)).toBe(successor);
    expect(preserveStreamingMessageContent({ ...current, id: 32 }, incoming)).toBe(incoming);
    expect(preserveStreamingMessageContent({ ...current, status: 'done' }, incoming)).toBe(incoming);
    expect(preserveStreamingMessageContent({ ...current, working: null }, incoming)).toBe(incoming);
    expect(preserveStreamingMessageContent(undefined, incoming)).toBe(incoming);
    expect(preserveStreamingMessageContent(persistedOnlyMessage(), incoming)).toBe(incoming);
  });
});

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
    ).toEqual({ items: [], media: [], parts: [changed!.parts[0]] });
  });

  it('acknowledges applied suffixes and resynchronizes canonical final content', async () => {
    const message = streamingMessage();
    const cursor = { epoch: 'worker', step: 200, sequence: 2, structure: 1,
      item: 'answer', content: 1, id: 'block', generation: 0, offset: 16 };
    const delta = { step_id: 200, step_sequence: 2, item_id: -102, item_sequence: 2,
      item_type: 'answer', content_id: -22001, sequence: 1, from: 16, to: 21, text: ' 🌍' };
    const canonical = persistedOnlyMessage().content!;
    mocks.get.mockResolvedValueOnce({ ...initial, content: message.content, view_revision: 'v1', runtime_cursor: cursor })
      .mockResolvedValueOnce({ ...initial, content: undefined, revision: 'r2', view_revision: 'v1',
        runtime_delta: delta, runtime_cursor: { ...cursor, offset: 21 } })
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ ...initial, status: 'done', content: canonical, content_revision: 'final', runtime_cursor: null });
    const { runtime, branch } = setupRuntime();
    await runtime.startPolling(31);
    await vi.advanceTimersByTimeAsync(500);
    expect(branch.value[0]!.content!.parts.at(-1)!.text).toBe('Streaming answer 🌍');
    expect(JSON.parse(new URL(mocks.get.mock.calls[1][0], 'http://test').searchParams.get('runtime_cursor')!)).toEqual(cursor);
    await vi.advanceTimersByTimeAsync(500);
    expect(JSON.parse(new URL(mocks.get.mock.calls[2][0], 'http://test').searchParams.get('runtime_cursor')!).offset).toBe(21);
    expect(branch.value[0]!.content!.parts.at(-1)!.text).toBe('Streaming answer 🌍');
    await vi.advanceTimersByTimeAsync(500);
    expect(branch.value[0]!.content).toEqual(canonical);
    expect(branch.value[0]!.status).toBe('done');
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

  it('hands preserved runtime content back to canonical polling content', async () => {
    const current = streamingMessage();
    const canonical = persistedOnlyMessage();
    canonical.working!.latest_step_status = 'waiting_tools';
    canonical.content!.parts.push({ step_id: 200, step_sequence: 2, item_id: 202, item_sequence: 2,
      content_id: 22001, sequence: 1, item_type: 'answer', text: 'Canonical answer' });
    mocks.get.mockResolvedValueOnce({ ...initial, content: current.content, working: current.working })
      .mockResolvedValue({ ...initial, content: canonical.content, working: canonical.working });
    const { runtime, branch } = setupRuntime();
    await runtime.startPolling(31);
    branch.value = [persistedOnlyMessage()];
    expect(branch.value[0]!.content!.parts.at(-1)!.text).toBe('Streaming answer');
    await vi.advanceTimersByTimeAsync(500);
    expect(branch.value[0]!.content).toEqual(canonical.content);
    expect(branch.value[0]!.content!.parts.every((part) => part.content_id > 0)).toBe(true);
  });

  it('never carries a streaming overlay across chat routes', async () => {
    const current = streamingMessage();
    mocks.get.mockResolvedValue({ ...initial, content: current.content, working: current.working });
    const { runtime, branch, chatId } = setupRuntime();
    await runtime.startPolling(31);
    chatId.value = 13;
    const incoming = persistedOnlyMessage();
    branch.value = [incoming];
    expect(branch.value[0]!.content).toEqual(incoming.content);
  });

  it('resynchronizes after a full branch reload and on resume', async () => {
    mocks.get.mockResolvedValue(initial);
    const { runtime, branch } = setupRuntime();
    await runtime.startPolling(31);
    branch.value = [{ id: 31, role: 'assistant', status: 'generating' }];
    await vi.advanceTimersByTimeAsync(500);
    expect(mocks.get.mock.calls[1][0]).toBe('/api/bff/chat-messages/31/poll?poll_protocol=cursor');
    expect(branch.value[0].content).toEqual(initial.content);
    await runtime.startPolling(31);
    expect(mocks.get.mock.calls[2][0]).toBe('/api/bff/chat-messages/31/poll?poll_protocol=cursor');
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

describe('client-owned runtime cursors', () => {
  const cursor = { epoch: 'owner', step: 200, sequence: 2, structure: 1,
    item: 'answer', content: 1, id: 'content', generation: 0, offset: 6 };
  const delta = { step_id: 200, step_sequence: 2, item_id: -102, item_sequence: 2,
    item_type: 'answer', content_id: -22001, sequence: 1, from: 6, to: 11, text: ' 🌍' };

  it('updates usage totals by scalar step differences', () => {
    const result = mergeRuntimeUsage({ latest_step: { id: 1, sequence: 1, output_tokens: 2, cost: 0.1 },
      total: { output_tokens: 12, cost: 0.6 }, total_cost: 0.6, subchat_cost: 0.2 },
      { id: 1, sequence: 1, output_tokens: 5, cost: 0.2 });
    expect(result.total!.output_tokens).toBe(15);
    expect(result.total_cost).toBeCloseTo(0.7);
    expect(result.combined_total_cost).toBeCloseTo(0.9);
  });

  it('selects answer even when reasoning was returned first', () => {
    expect(selectRuntimeCursor({ ...initial, runtime_cursor: { ...cursor, item: 'reasoning' },
      runtime_targets: [{ item_type: 'reasoning', cursor: { ...cursor, item: 'reasoning' } },
        { item_type: 'answer', cursor }] })).toEqual(cursor);
  });

  it('checks UTF-8 bytes from the acknowledged cursor, not JavaScript character counts', () => {
    expect(validRuntimeDelta(cursor, delta)).toBe(true);
    expect(validRuntimeDelta({ ...cursor, offset: 7 }, delta)).toBe(false);
    expect(validRuntimeDelta(cursor, { ...delta, to: 9 })).toBe(false);
    expect(validRuntimeDelta({ ...cursor, step: 201 }, delta)).toBe(false);
  });

  it('appends only the chosen block and preserves completed content', () => {
    const current = streamingMessage().content!;
    const response = { ...initial, content: undefined, runtime_delta: delta };
    const merged = mergeRuntimePollContent(current, response)!;
    expect(merged.parts[0]).toEqual(current.parts[0]);
    expect(merged.parts.at(-1)!.text).toBe('Streaming answer 🌍');
    expect(current.parts.at(-1)!.text).toBe('Streaming answer');
  });

  it('creates a previously empty answer block only from offset zero', () => {
    const current = { items: [], parts: [], media: [] };
    expect(mergeRuntimePollContent(current, { ...initial, content: undefined,
      runtime_delta: { ...delta, from: 0, to: 5 } })!.parts[0]!.text).toBe(' 🌍');
    expect(() => mergeRuntimePollContent(current, { ...initial, content: undefined, runtime_delta: delta })).toThrow();
  });
});
