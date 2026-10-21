import { computed, ref } from 'vue';

const ashMocks = vi.hoisted(() => ({
  updateChatRecord: vi.fn(),
}));

vi.mock('@/features/chat/chatAshApi', () => ({
  copyChatRecord: vi.fn(),
  createChatRecord: vi.fn(),
  deleteChatRecord: vi.fn(),
  updateChatRecord: ashMocks.updateChatRecord,
}));

import { useChatHeaderControls } from '@/features/chat/model/useChatHeaderControls';
import type { Chat, ChatBranchMessage, LlmConfiguration } from '@/types/api';

const configs: LlmConfiguration[] = [
  { id: 7, label: 'Model A', enabled: true },
  { id: 8, label: 'Model B', enabled: true },
];

const deferred = () => {
  let resolve: () => void = () => {};
  let reject: (error: unknown) => void = () => {};
  const promise = new Promise<void>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
};

const flush = async () => {
  for (let i = 0; i < 5; i += 1) await Promise.resolve();
};

const createControls = () => {
  const chatId = ref(1);
  const chat = ref<Chat | null>({ id: 1, llm_configuration_id: 7 } as Chat);
  const activeGenerationId = ref<number | null>(null);
  const branch = ref<ChatBranchMessage[]>([]);
  const refreshPromptContext = vi.fn().mockResolvedValue(undefined);

  const controls = useChatHeaderControls({
    chatId: computed(() => chatId.value),
    routeFullPath: () => '/chats/1',
    chat,
    chatNote: ref(''),
    canEdit: computed(() => true),
    bots: ref([]),
    noBotSortActivityAt: ref(null),
    chatBlockCount: ref(0),
    chatToolCount: ref(0),
    llmConfigurations: ref(configs),
    artifactToolsAvailable: ref(false),
    activeGenerationId,
    branch,
    menuOpen: ref(false),
    deleting: ref(false),
    toggleMenu: () => {},
    closeMenu: () => {},
    stackOpen: () => {},
    pushRoute: async () => undefined,
    reloadChat: async () => undefined,
    refreshPromptContext,
  });
  controls.hydrate({ selectedConfig: 7 });

  return { controls, chat, chatId, activeGenerationId, branch };
};

const generatingMessage = (configId: number): ChatBranchMessage =>
  ({ id: 42, role: 'assistant', status: 'generating', llm_configuration_id: configId }) as ChatBranchMessage;

describe('useChatHeaderControls configuration selection', () => {
  beforeEach(() => {
    ashMocks.updateChatRecord.mockReset();
  });

  it('changes the chat configuration while a response is generating', async () => {
    ashMocks.updateChatRecord.mockResolvedValue(undefined);
    const { controls, chat, activeGenerationId, branch } = createControls();
    activeGenerationId.value = 42;
    branch.value = [generatingMessage(7)];
    const alert = vi.spyOn(window, 'alert').mockImplementation(() => {});

    controls.selectedConfig.value = 8;
    await controls.updateConfig();

    expect(alert).not.toHaveBeenCalled();
    expect(ashMocks.updateChatRecord).toHaveBeenCalledWith(1, { llm_configuration_id: 8 });
    expect(chat.value?.llm_configuration_id).toBe(8);
    expect(controls.configSyncStatus.value).toBe('synced');
  });

  it('labels a running generation whose pinned configuration differs from the selection', () => {
    const { controls, activeGenerationId, branch } = createControls();
    activeGenerationId.value = 42;
    branch.value = [generatingMessage(7)];

    expect(controls.activeGenerationConfigMismatchLabel.value).toBe('');
    expect(controls.generationConfigMismatchLabel(branch.value[0])).toBe('');

    controls.selectedConfig.value = 8;
    expect(controls.activeGenerationConfigMismatchLabel.value).toBe('Model A');
    expect(controls.generationConfigMismatchLabel(branch.value[0])).toBe('Model A');
    expect(
      controls.generationConfigMismatchLabel({ ...generatingMessage(7), status: 'done' } as ChatBranchMessage)
    ).toBe('');
  });

  it('does not label a generation outside the visible branch', () => {
    const { controls, activeGenerationId, branch } = createControls();
    activeGenerationId.value = 99;
    branch.value = [generatingMessage(7)];
    controls.selectedConfig.value = 8;

    expect(controls.activeGenerationConfigMismatchLabel.value).toBe('');
  });

  it('keeps a pending selection when a chat read lands before the server confirms it', async () => {
    const write = deferred();
    ashMocks.updateChatRecord.mockReturnValueOnce(write.promise);
    const { controls, chat } = createControls();

    controls.selectedConfig.value = 8;
    const updating = controls.updateConfig();
    let synced = false;
    void controls.waitForConfigSync(60_000).then((ready) => {
      synced = ready;
    });

    chat.value = { id: 1, llm_configuration_id: 7 } as Chat;
    controls.hydrate({ selectedConfig: 7, configReadRevision: controls.configReadRevision() });
    await flush();

    expect(controls.selectedConfig.value).toBe(8);
    expect(controls.isConfigSyncPending.value).toBe(true);
    expect(synced).toBe(false);

    write.resolve();
    await updating;
    await flush();

    expect(synced).toBe(true);
    expect(controls.selectedConfig.value).toBe(8);
    expect(chat.value?.llm_configuration_id).toBe(8);
  });

  it('ignores a read that started before a configuration write completed', async () => {
    ashMocks.updateChatRecord.mockResolvedValueOnce(undefined);
    const { controls, chat } = createControls();
    const staleRevision = controls.configReadRevision();

    controls.selectedConfig.value = 8;
    await controls.updateConfig();

    chat.value = { id: 1, llm_configuration_id: 7 } as Chat;
    controls.hydrate({ selectedConfig: 7, configReadRevision: staleRevision });

    expect(controls.selectedConfig.value).toBe(8);
    expect(chat.value?.llm_configuration_id).toBe(8);

    chat.value = { id: 1, llm_configuration_id: 7 } as Chat;
    controls.hydrate({ selectedConfig: 7, configReadRevision: controls.configReadRevision() });
    expect(controls.selectedConfig.value).toBe(7);
  });

  it('drops a pending write when the chat state is reset for another chat', async () => {
    const write = deferred();
    ashMocks.updateChatRecord.mockReturnValueOnce(write.promise);
    const { controls, chat, chatId } = createControls();

    controls.selectedConfig.value = 8;
    const updating = controls.updateConfig();

    chatId.value = 2;
    controls.resetConfigState();
    expect(controls.isConfigSyncPending.value).toBe(false);
    expect(await controls.waitForConfigSync()).toBe(true);

    chat.value = { id: 2, llm_configuration_id: 3 } as Chat;
    controls.hydrate({ selectedConfig: 3, configReadRevision: controls.configReadRevision() });

    write.resolve();
    await updating;

    expect(controls.selectedConfig.value).toBe(3);
    expect(chat.value?.llm_configuration_id).toBe(3);
  });
});
