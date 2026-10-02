import { computed, effectScope, nextTick, ref } from 'vue';

const mocks = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn() }));
vi.mock('@/api/client', () => ({
  api: mocks,
  getApiErrorMessage: (_: unknown, fallback: string) => fallback,
}));
vi.mock('@/features/chat/chatEvents', () => ({ publishChatChange: vi.fn() }));

import { useChatMessageActions } from '@/features/chat/model/useChatMessageActions';
import type { ChatBranchMessage, ChatMessageStep } from '@/types/api';

const step = (id: number): ChatMessageStep => ({
  id,
  sequence: id,
  status: 'waiting_provider',
  items: [],
});
const cleanups: (() => void)[] = [];
function setupActions() {
  const chatId = ref(1);
  const branch = ref<ChatBranchMessage[]>([{ id: 10, role: 'assistant', status: 'generating' }]);
  const scope = effectScope();
  const actions = scope.run(() =>
    useChatMessageActions({
      chatId: computed(() => chatId.value),
      chat: ref(null),
      readOnly: computed(() => false),
      branch,
      selectedConfig: ref(''),
      fileUploadPolicy: computed(() => ({
        allowsFiles: true,
        imagesOnly: false,
        maxFileSizeBytes: 1024,
        accept: '',
      })),
      waitForConfigSync: async () => true,
      messageConfigLabel: () => '',
      startPolling: async () => {},
      scrollToLastMessage: () => {},
      ensurePendingFilesUploaded: async () => [],
      removePendingFileFromCollection: async () => {},
      clearPendingFilesCollection: async () => {},
      pushChatRoute: () => {},
    })
  )!;
  cleanups.push(() => {
    void actions.dispose();
    scope.stop();
  });
  return { actions, chatId, branch };
}

describe('working panel polling revisions', () => {
  beforeEach(() => {
    mocks.get.mockReset();
    mocks.post.mockReset();
  });
  afterEach(() => {
    cleanups.splice(0).forEach((cleanup) => cleanup());
  });

  it('stays on the opened step while new steps extend the list', async () => {
    mocks.get.mockResolvedValue({
      message_id: 10,
      steps: [step(1)],
      selected_step_id: 1,
      step: step(1),
      revision: 'd1',
    });
    const { actions } = setupActions();
    actions.toggleWorking(10);
    await nextTick();
    expect(actions.getOpenWorkingPollRequest(10)).toBe('1');
    expect(actions.getOpenWorkingPollRevision(10)).toBe('d1');
    actions.applyWorkingPoll(10, undefined);
    expect(actions.workingStateFor(10)?.selectedStep?.id).toBe(1);
    actions.applyWorkingPoll(10, { selected_step_id: 1, steps: [step(1), step(2)], revision: 'd1' });
    expect(actions.workingStateFor(10)?.selectedStep?.id).toBe(1);
    expect(actions.workingStateFor(10)?.steps).toHaveLength(2);
    actions.applyWorkingPoll(10, {
      selected_step_id: 3,
      step: step(3),
      steps: [step(1), step(2), step(3)],
      revision: 'd3',
    });
    expect(actions.workingStateFor(10)?.selectedStep?.id).toBe(1);
    expect(actions.workingStateFor(10)?.steps).toHaveLength(3);
    expect(actions.getOpenWorkingPollRequest(10)).toBe('1');
    expect(actions.getOpenWorkingPollRevision(10)).toBe('d1');
  });

  it('picks up the first step when opened before any step exists, then stays on it', async () => {
    mocks.get.mockResolvedValue({
      message_id: 10,
      steps: [],
      selected_step_id: null,
      step: null,
      revision: 'empty',
    });
    const { actions } = setupActions();
    actions.toggleWorking(10);
    await nextTick();
    expect(actions.getOpenWorkingPollRequest(10)).toBe('latest');
    actions.applyWorkingPoll(10, {
      selected_step_id: 1,
      step: step(1),
      steps: [step(1)],
      revision: 'd1',
    });
    expect(actions.workingStateFor(10)?.selectedStep?.id).toBe(1);
    expect(actions.getOpenWorkingPollRequest(10)).toBe('1');
    actions.applyWorkingPoll(10, {
      selected_step_id: 2,
      step: step(2),
      steps: [step(1), step(2)],
      revision: 'd2',
    });
    expect(actions.workingStateFor(10)?.selectedStep?.id).toBe(1);
    expect(actions.workingStateFor(10)?.steps).toHaveLength(2);
  });

  it('keeps historical selection while accepting summary changes', async () => {
    mocks.get.mockResolvedValue({
      message_id: 10,
      steps: [step(1), step(2)],
      selected_step_id: 1,
      step: step(1),
      revision: 'old',
    });
    const { actions } = setupActions();
    actions.toggleWorking(10);
    await nextTick();
    actions.selectWorkingStep(10, 1);
    await nextTick();
    expect(actions.getOpenWorkingPollRequest(10)).toBe('1');
    actions.applyWorkingPoll(10, {
      selected_step_id: 1,
      steps: [step(1), step(2), step(3)],
      revision: 'old',
    });
    expect(actions.workingStateFor(10)?.steps).toHaveLength(3);
    expect(actions.workingStateFor(10)?.selectedStep?.id).toBe(1);
    actions.applyWorkingPoll(10, { selected_step_id: 3, step: step(3), revision: 'new' });
    expect(actions.workingStateFor(10)?.selectedStep?.id).toBe(1);
  });

  it('does not reuse an old detail after explicit clearing and a new selection', async () => {
    mocks.get.mockResolvedValue({
      message_id: 10,
      steps: [step(1)],
      selected_step_id: 1,
      step: step(1),
      revision: 'one',
    });
    const { actions } = setupActions();
    actions.toggleWorking(10);
    await nextTick();
    actions.applyWorkingPoll(10, { selected_step_id: null, step: null, revision: 'empty' });
    expect(actions.workingStateFor(10)?.selectedStepId).toBeNull();
    expect(actions.workingStateFor(10)?.selectedStep).toBeNull();
    actions.applyWorkingPoll(10, { selected_step_id: 2, revision: 'two' });
    expect(actions.workingStateFor(10)?.selectedStepId).toBe(2);
    expect(actions.workingStateFor(10)?.selectedStep).toBeNull();
    expect(actions.getOpenWorkingPollRevision(10)).toBeUndefined();
  });

  it('reloads detail after full reload and clears revision on route switches', async () => {
    mocks.get
      .mockResolvedValueOnce({
        message_id: 10,
        steps: [step(1)],
        selected_step_id: 1,
        step: step(1),
        revision: 'before',
      })
      .mockResolvedValue({
        message_id: 10,
        steps: [step(2)],
        selected_step_id: 2,
        step: step(2),
        revision: 'after',
      });
    const { actions, branch, chatId } = setupActions();
    actions.toggleWorking(10);
    await nextTick();
    branch.value = [{ id: 10, role: 'assistant', status: 'generating' }];
    expect(actions.getOpenWorkingPollRevision(10)).toBeUndefined();
    await nextTick();
    expect(actions.getOpenWorkingPollRevision(10)).toBe('after');
    chatId.value = 2;
    expect(actions.workingStateFor(10)).toBeNull();
    expect(actions.getOpenWorkingPollRevision(10)).toBeUndefined();
  });
});
