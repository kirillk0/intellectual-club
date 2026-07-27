import { mount, type VueWrapper } from '@vue/test-utils';
import { ref, type Component } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

const viewModelMocks = vi.hoisted(() => ({
  useChatViewModel: vi.fn(),
}));

vi.mock('@/features/chat/useChatViewModel', () => viewModelMocks);

import ChatView from '@/views/ChatView.vue';
import { i18n, setPreferredLocale } from '@/i18n';

let activeWrapper: VueWrapper | null = null;

async function mountChatView(stubs: Record<string, boolean | Component> = {}) {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/chats/:id', name: 'chat', component: { template: '<div />' } }],
  });
  await router.push('/chats/1');
  await router.isReady();

  activeWrapper = mount(ChatView, {
    global: {
      plugins: [router, i18n],
      stubs,
    },
  });

  return activeWrapper;
}

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

  it('shows Steer, Queue, and Cancel together and keeps the shortcut on Steer', async () => {
    const submitComposer = vi.fn();
    const queueMessage = vi.fn();
    viewModelMocks.useChatViewModel.mockReturnValue({
      loaded: ref(true),
      chatUnavailable: ref(false),
      chat: ref({ id: 1, bot_id: null, llm_configuration_id: 27 }),
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
      sharedReadonly: ref(false),
      continuingConversation: ref(false),
      queuedMessages: ref([]),
      queuedFollowUpHeadId: ref(null),
      queueActionId: ref(null),
      pendingFiles: ref([]),
      activeGenerationId: ref(31),
      cancelingGenerationId: ref(null),
      steeringGenerationId: ref(null),
      canSteerGeneration: ref(true),
      supportsActiveGenerationSteering: ref(true),
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
      submitComposer,
      queueMessage,
      steerGeneration: vi.fn(),
      cancelActiveGeneration: vi.fn(),
      handleCancelPointerDown: vi.fn(),
      onPendingFilesSelected: vi.fn(),
      addPendingFiles: vi.fn(),
      backToChats: vi.fn(),
      setMessageRef: vi.fn(),
    });

    const wrapper = await mountChatView({
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
      Teleport: true,
    });

    expect(wrapper.findAll('.chat-composer__actions > button').map((button) => button.text())).toEqual([
      'Attach',
      'Steer',
      'Queue',
      'Cancel',
    ]);
    await wrapper.get('.chat-composer__queue').trigger('click');
    expect(queueMessage).toHaveBeenCalledTimes(1);
    await wrapper.get('textarea').trigger('keydown', { key: 'Enter', ctrlKey: true });
    expect(submitComposer).toHaveBeenCalledTimes(1);
  });
});
