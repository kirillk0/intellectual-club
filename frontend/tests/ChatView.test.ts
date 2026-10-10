import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { ref, type Component } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

const viewModelMocks = vi.hoisted(() => ({
  useChatViewModel: vi.fn(),
}));

vi.mock('@/features/chat/useChatViewModel', () => viewModelMocks);

import ChatView from '@/views/ChatView.vue';
import { i18n, setPreferredLocale } from '@/i18n';

let activeWrapper: VueWrapper | null = null;

async function mountChatView(
  stubs: Record<string, boolean | Component> = {},
  attachTo?: HTMLElement
) {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/chats/:id', name: 'chat', component: { template: '<div />' } }],
  });
  await router.push('/chats/1');
  await router.isReady();

  activeWrapper = mount(ChatView, {
    attachTo,
    global: {
      plugins: [router, i18n],
      stubs,
    },
  });

  return activeWrapper;
}

function loadedChatViewModel({
  historyReadOnly = false,
  sharedReadOnly = false,
}: { historyReadOnly?: boolean; sharedReadOnly?: boolean } = {}) {
  return {
    loaded: ref(true),
    chatUnavailable: ref(false),
    chat: ref({ id: 1, bot_id: null, llm_configuration_id: 27, history_read_only: historyReadOnly }),
    historyReadonly: ref(historyReadOnly || sharedReadOnly),
    chatSettingsReady: ref(true),
    chatSettingsStatus: ref('ready'),
    chatSettingsError: ref(''),
    loadError: ref(''),
    chatFullTitle: ref('Queue test'),
    chatBaseTitle: ref('Queue test'),
    gridColumns: ref('1fr'),
    leftOpen: ref(false),
    rightOpen: ref(false),
    isMobile: ref(false),
    branch: ref([]),
    fallbackChildRelations: ref([]),
    parentRelationBanner: ref(null),
    handoffPending: ref(false),
    sharedReadonly: ref(sharedReadOnly),
    continuingConversation: ref(false),
    queuedMessages: ref([]),
    queuedFollowUpHeadId: ref(null),
    queueActionId: ref(null),
    pendingFiles: ref([]),
    activeGenerationId: ref(31),
    cancelingGenerationId: ref(null),
    steeringGenerationId: ref(null),
    canSteerGeneration: ref(true),
    hasSendPayload: ref(true),
    hasFollowUpBacklog: ref(false),
    sending: ref(false),
    isConfigSyncPending: ref(false),
    draft: ref('direction'),
    canAttachFiles: ref(true),
    fileAttachTitle: ref('Attach files'),
    fileInputAccept: ref(''),
    fileDropHint: ref('Drop files'),
    steerButtonLabel: ref('Steer'),
    queueButtonLabel: ref('Queue'),
    cancelButtonLabel: ref('Cancel'),
    generationPollReconnecting: ref(false),
    editingMessage: ref(null),
    editingQueuedMessage: ref(null),
    queuedEditContents: ref([]),
    queuedEditExistingAttachments: ref([]),
    queuedEditPendingFiles: ref([]),
    queuedEditError: ref(''),
    savingQueuedEdit: ref(false),
    submitComposer: vi.fn(),
    queueMessage: vi.fn(),
    steerGeneration: vi.fn(),
    cancelActiveGeneration: vi.fn(),
    handleCancelPointerDown: vi.fn(),
    onPendingFilesSelected: vi.fn(),
    addPendingFiles: vi.fn(),
    backToChats: vi.fn(),
    setMessageRef: vi.fn(),
  };
}

const loadedChatStubs = {
  StackToolbarTeleport: { template: '<div><slot /></div>' },
  ChatHeaderToolbar: true,
  ChatQueuedMessagesPanel: true,
  ChatEditMessageModal: true,
  ChatAttachmentPreviewModal: true,
  ChatPromptModal: true,
  ChatNoteModal: true,
  ChatMessageStatsModal: true,
  ChatStepDetailsModal: true,
  ChatStepRawModal: true,
  ShareWithGroupsModal: true,
  BotSelectorModal: true,
  KnowledgeBlocksPickerModal: true,
  ChatMessageTreeOverlay: true,
};

describe('ChatView loading state', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = '<div id="toolbar-host"></div>';
    viewModelMocks.useChatViewModel.mockReset();
    viewModelMocks.useChatViewModel.mockReturnValue({
      loaded: ref(false),
      chat: ref(null),
      sharedReadonly: ref(false),
      handoffPending: ref(false),
      backToChats: vi.fn(),
      retryLoadChat: vi.fn(),
    });
    setPreferredLocale('en');
  });

  afterEach(() => {
    activeWrapper?.unmount();
    activeWrapper = null;
    document.body.innerHTML = '';
    setPreferredLocale(null);
    vi.useRealTimers();
  });

  it('shows the disabled chat frame immediately and delays the recovery notice', async () => {
    const wrapper = await mountChatView();

    expect(wrapper.find('.spa-boot').exists()).toBe(false);
    expect(wrapper.get('.chat-page--initializing').attributes('aria-busy')).toBe('true');
    expect(wrapper.find('.message-list').exists()).toBe(true);
    expect(wrapper.get('textarea').attributes('disabled')).toBeDefined();
    expect(wrapper.find('[role="status"]').exists()).toBe(false);
    await vi.advanceTimersByTimeAsync(1_999);
    expect(wrapper.find('[role="status"]').exists()).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    expect(wrapper.get('[role="status"]').text()).toContain('Loading chat…');
    expect(wrapper.get('[role="status"] button').text()).toBe('Retry now');
    expect(wrapper.text()).toContain('Attach');
    expect(wrapper.text()).toContain('Send');
    expect(document.querySelector('#toolbar-host')?.textContent).toContain('Close');
    expect(document.body.textContent).not.toContain('Reload');
  });

  it('translates the initial chat frame', async () => {
    setPreferredLocale('ru');
    const wrapper = await mountChatView();

    expect(wrapper.get('textarea').attributes('placeholder')).toBe('Введите сообщение');
    expect(wrapper.text()).toContain('Прикрепить');
    expect(wrapper.text()).toContain('Отправить');
    expect(wrapper.find('[role="status"]').exists()).toBe(false);
    await vi.advanceTimersByTimeAsync(2_000);
    expect(wrapper.get('[role="status"] button').text()).toBe('Повторить сейчас');
    expect(document.querySelector('#toolbar-host')?.textContent).toContain('Закрыть');
  });

  it.each([[false, false], [true, false], [false, true], [true, true]])('preserves composer availability (linked=%s, shared=%s)', async (historyReadOnly, sharedReadOnly) => {
    const viewModel = loadedChatViewModel({ historyReadOnly, sharedReadOnly });
    viewModelMocks.useChatViewModel.mockReturnValue(viewModel);

    const wrapper = await mountChatView({ ...loadedChatStubs, Teleport: true });

    if (sharedReadOnly) {
      expect(wrapper.find('.chat-readonly-panel').exists()).toBe(true);
      expect(wrapper.find('.chat-readonly-panel button').exists()).toBe(!historyReadOnly);
      expect(wrapper.find('.chat-input-form').exists()).toBe(false);
      if (historyReadOnly) expect(wrapper.text()).toContain('This shared fork cannot be copied');
      return;
    }

    expect(wrapper.findAll('.chat-composer__actions > button').map((button) => button.text())).toEqual([
      'Attach',
      'Steer',
      'Queue',
      'Cancel',
    ]);
    await wrapper.get('.chat-composer__queue').trigger('click');
    expect(viewModel.queueMessage).toHaveBeenCalledTimes(1);
    await wrapper.get('textarea').trigger('keydown', { key: 'Enter', ctrlKey: true });
    expect(viewModel.submitComposer).toHaveBeenCalledTimes(1);
  });
});

describe('ChatView composer expansion', () => {
  const originalScrollIntoView = Element.prototype.scrollIntoView;

  const expandedLayer = () =>
    document.querySelector<HTMLElement>('body > .chat-composer-layer--expanded');

  async function mountLoadedChat(viewModel = loadedChatViewModel()) {
    viewModelMocks.useChatViewModel.mockReturnValue(viewModel);
    const wrapper = await mountChatView(loadedChatStubs, document.getElementById('app')!);
    return { wrapper, viewModel };
  }

  beforeEach(() => {
    document.body.innerHTML = '<div id="toolbar-host"></div><div id="app"></div>';
    Element.prototype.scrollIntoView = vi.fn();
    viewModelMocks.useChatViewModel.mockReset();
    setPreferredLocale('en');
  });

  afterEach(() => {
    activeWrapper?.unmount();
    activeWrapper = null;
    document.body.innerHTML = '';
    Element.prototype.scrollIntoView = originalScrollIntoView;
    setPreferredLocale(null);
  });

  it('moves the same composer into a full-screen editor and back, keeping focus and selection', async () => {
    const { wrapper } = await mountLoadedChat();
    const textarea = wrapper.get<HTMLTextAreaElement>('textarea').element;
    textarea.focus();
    textarea.setSelectionRange(2, 4);

    await wrapper.get('.chat-composer__expand').trigger('click');
    await flushPromises();

    const layer = expandedLayer();
    expect(layer?.getAttribute('role')).toBe('dialog');
    expect(layer?.getAttribute('aria-label')).toBe('Message editor');
    expect(layer?.contains(textarea)).toBe(true);
    expect(layer?.querySelector('.chat-composer__expand')?.getAttribute('aria-label')).toBe(
      'Collapse message editor'
    );
    expect(document.activeElement).toBe(textarea);
    expect([textarea.selectionStart, textarea.selectionEnd]).toEqual([2, 4]);
    expect(document.body.style.position).toBe('fixed');

    textarea.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    await flushPromises();

    expect(expandedLayer()).toBeNull();
    expect(wrapper.get('.chat-window').element.contains(textarea)).toBe(true);
    expect(document.activeElement).toBe(textarea);
    expect(document.body.style.position).toBe('');
  });

  it('returns to the conversation when the message is sent from the expanded editor', async () => {
    const { wrapper, viewModel } = await mountLoadedChat();

    await wrapper.get('.chat-composer__expand').trigger('click');
    await flushPromises();
    expandedLayer()?.querySelector<HTMLButtonElement>('.chat-composer__queue')?.click();
    await flushPromises();

    expect(viewModel.queueMessage).toHaveBeenCalledTimes(1);
    expect(expandedLayer()).toBeNull();
    expect(document.body.style.position).toBe('');
  });

  it('stays expanded while the chat refreshes and collapses when another chat opens', async () => {
    const { wrapper, viewModel } = await mountLoadedChat();

    await wrapper.get('.chat-composer__expand').trigger('click');
    await flushPromises();

    viewModel.chat.value = { ...viewModel.chat.value };
    await flushPromises();
    expect(expandedLayer()).not.toBeNull();

    viewModel.chat.value = { ...viewModel.chat.value, id: 2 };
    await flushPromises();
    expect(expandedLayer()).toBeNull();
    expect(document.body.style.position).toBe('');
  });

  it('releases the expanded editor when the chat view unmounts', async () => {
    const { wrapper } = await mountLoadedChat();

    await wrapper.get('.chat-composer__expand').trigger('click');
    await flushPromises();
    expect(expandedLayer()).not.toBeNull();

    activeWrapper?.unmount();
    activeWrapper = null;

    expect(expandedLayer()).toBeNull();
    expect(document.body.style.position).toBe('');
  });
});
