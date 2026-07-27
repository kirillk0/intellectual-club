import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { defineComponent, h } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  post: vi.fn(),
  put: vi.fn(),
  patch: vi.fn(),
  del: vi.fn(),
}));

vi.mock('@/api/client', () => ({
  api: apiMocks,
  getApiErrorMessage: (error: unknown, fallback: string) =>
    error instanceof Error && error.message ? error.message : fallback,
  isHttpError: (error: unknown) =>
    error instanceof Error && typeof (error as Error & { status?: unknown }).status === 'number',
}));

import type {
  ChatSettingsStatePayload,
  ChatStatePayload,
} from '@/features/chat/model/chatViewModel.shared';
import { useChatViewModel } from '@/features/chat/useChatViewModel';
import { useNavigationStack } from '@/features/stack/navigationStack';

type ChatViewModel = ReturnType<typeof useChatViewModel>;

const chatState = (
  id: number,
  llmConfigurationId: number | null = null
): ChatStatePayload => ({
  chat: {
    id,
    bot_id: null,
    llm_configuration_id: llmConfigurationId,
    can_edit: true,
    shared_incoming: false,
  } as ChatStatePayload['chat'],
  branch: [],
  relations: {
    parent: null,
    children_by_message_id: {},
    children_without_message: [],
  },
  continuation_nav: [],
  active_generation_message_id: null,
  idle_revision: `revision-${id}`,
});

const chatSettings = (
  llmConfigurations: ChatSettingsStatePayload['options']['llm_configurations'] = []
): ChatSettingsStatePayload => ({
  chat_blocks: [],
  chat_tool_bindings: [],
  prompt_sources: {
    bot: [],
    chat: [],
    configuration: [],
    user: [],
  },
  prompt_blocks: [],
  compiled_prompt_text: '',
  counters: {
    prompt_token_count: 0,
    history_token_count: 0,
    history_message_count: 0,
  },
  active_tool_instances: [],
  active_tool_bindings: [],
  artifact_tools_available: false,
  missing_required_per_user_tool_aliases: [],
  options: {
    bots: [],
    llm_configurations: llmConfigurations,
    knowledge_blocks: [],
    tool_instances: [],
  },
});

let activeWrapper: VueWrapper | null = null;

async function mountViewModel(path = '/chats/1', previousPath?: string) {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/chats', name: 'chats', component: { template: '<div />' } },
      { path: '/chats/:id', name: 'chat', component: { template: '<div />' } },
    ],
  });
  let previousRoute = null;
  if (previousPath) {
    await router.push(previousPath);
    previousRoute = router.currentRoute.value;
  }
  await router.push(path);
  await router.isReady();

  let viewModel!: ChatViewModel;
  const Harness = defineComponent({
    setup() {
      viewModel = useChatViewModel();
      return () => h('div');
    },
  });

  activeWrapper = mount(Harness, { global: { plugins: [router] } });
  return { viewModel, router, previousRoute };
}

describe('useChatViewModel loading', () => {
  beforeEach(() => {
    Object.values(apiMocks).forEach((mock) => mock.mockReset());
    apiMocks.post.mockResolvedValue(undefined);
    apiMocks.put.mockResolvedValue(undefined);
    apiMocks.patch.mockResolvedValue(undefined);
    apiMocks.del.mockResolvedValue(undefined);
    vi.stubGlobal('matchMedia', () => ({
      matches: false,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    }));
  });

  afterEach(() => {
    activeWrapper?.unmount();
    activeWrapper = null;
    useNavigationStack().reset();
    vi.unstubAllGlobals();
  });

  it('returns to the parent chat after opening a subchat from a stacked chat', async () => {
    apiMocks.get.mockImplementation((path: string) => {
      if (path.endsWith('/settings')) return Promise.resolve(chatSettings());
      const match = path.match(/^\/api\/bff\/chat-state\/(\d+)$/u);
      return match ? Promise.resolve(chatState(Number(match[1]))) : Promise.resolve(undefined);
    });

    const { viewModel, router, previousRoute } = await mountViewModel('/chats/1', '/chats');
    if (!previousRoute) throw new Error('Missing previous chat list route');
    const stack = useNavigationStack();
    stack.markPendingPush(0);
    stack.commitPendingPush(previousRoute);

    await viewModel.openChat(2);
    expect(router.currentRoute.value.fullPath).toBe('/chats/2');

    router.back();
    await vi.waitFor(() => expect(router.currentRoute.value.fullPath).toBe('/chats/1'));
  });

  it('shows the chat after the core response while settings are still pending', async () => {
    let resolveSettings!: (payload: ChatSettingsStatePayload) => void;
    const settingsRequest = new Promise<ChatSettingsStatePayload>((resolve) => {
      resolveSettings = resolve;
    });

    apiMocks.get.mockImplementation((path: string) => {
      if (path === '/api/bff/chat-state/1/settings') return settingsRequest;
      if (path === '/api/bff/chat-state/1') return Promise.resolve(chatState(1, 27));
      return Promise.resolve(undefined);
    });

    const { viewModel } = await mountViewModel();

    await vi.waitFor(() => expect(viewModel.loaded.value).toBe(true));
    expect(viewModel.chat.value?.id).toBe(1);
    expect(viewModel.selectedConfig.value).toBe(27);
    expect(viewModel.chatSettingsStatus.value).toBe('loading');
    expect(viewModel.loadError.value).toBe('');
    expect(apiMocks.get).toHaveBeenCalledWith(
      '/api/bff/chat-state/1',
      expect.objectContaining({ retry: false, signal: expect.any(AbortSignal) })
    );
    expect(apiMocks.get).toHaveBeenCalledWith(
      '/api/bff/chat-state/1/settings',
      expect.objectContaining({ retry: false, signal: expect.any(AbortSignal) })
    );

    resolveSettings(chatSettings());
    await flushPromises();
    expect(viewModel.chatSettingsStatus.value).toBe('ready');
  });

  it('hydrates durable queued messages from the core chat state', async () => {
    const state = chatState(1);
    state.queued_messages = [
      {
        id: 91,
        chat_id: 1,
        kind: 'follow_up',
        status: 'blocked',
        anchor_message_id: 40,
        blocked_reason: 'generation_error',
        contents: [{ id: 911, sequence: 1, kind: 'text', content_text: 'Try once more' }],
      },
    ];
    apiMocks.get.mockImplementation((path: string) => {
      if (path.endsWith('/settings')) return Promise.resolve(chatSettings());
      if (path === '/api/bff/chat-state/1') return Promise.resolve(state);
      return Promise.resolve(undefined);
    });

    const { viewModel } = await mountViewModel();
    await vi.waitFor(() => expect(viewModel.loaded.value).toBe(true));

    expect(viewModel.queuedMessages.value).toEqual(state.queued_messages);
    expect(viewModel.hasFollowUpBacklog.value).toBe(true);
  });

  it('shows an explicit recoverable state when secondary settings fail terminally', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    apiMocks.get.mockImplementation((path: string) => {
      if (path === '/api/bff/chat-state/1/settings') {
        return Promise.reject(
          Object.assign(new Error('Settings are unavailable.'), { status: 400 })
        );
      }
      if (path === '/api/bff/chat-state/1') return Promise.resolve(chatState(1));
      return Promise.resolve(undefined);
    });

    const { viewModel } = await mountViewModel();

    await vi.waitFor(() => expect(viewModel.chat.value?.id).toBe(1));
    await flushPromises();
    expect(viewModel.loaded.value).toBe(true);
    expect(viewModel.loadError.value).toBe('');
    expect(viewModel.chatSettingsStatus.value).toBe('error');
    expect(viewModel.chatSettingsError.value).toBe('Settings are unavailable.');
    expect(warn).toHaveBeenCalledWith(
      'Failed to load secondary chat settings.',
      expect.any(Error)
    );

    apiMocks.get.mockImplementation((path: string) => {
      if (path === '/api/bff/chat-state/1/settings') {
        return Promise.resolve(chatSettings());
      }
      if (path === '/api/bff/chat-state/1') return Promise.resolve(chatState(1));
      return Promise.resolve(undefined);
    });
    viewModel.retryChatSettings();
    await vi.waitFor(() => expect(viewModel.chatSettingsStatus.value).toBe('ready'));
  });

  it('keeps the core configuration when settings arrive before the core chat', async () => {
    let resolveCore!: (payload: ChatStatePayload) => void;
    const configuration = {
      id: 27,
      label: 'Primary',
      enabled: true,
    } as ChatSettingsStatePayload['options']['llm_configurations'][number];

    apiMocks.get.mockImplementation((path: string) => {
      if (path === '/api/bff/chat-state/1/settings') {
        return Promise.resolve(chatSettings([configuration]));
      }
      if (path === '/api/bff/chat-state/1') {
        return new Promise<ChatStatePayload>((resolve) => {
          resolveCore = resolve;
        });
      }
      return Promise.resolve(undefined);
    });

    const { viewModel } = await mountViewModel();
    await vi.waitFor(() => expect(viewModel.chatSettingsStatus.value).toBe('ready'));

    resolveCore(chatState(1, 27));
    await vi.waitFor(() => expect(viewModel.chat.value?.id).toBe(1));

    expect(viewModel.selectedConfig.value).toBe(27);
    expect(viewModel.llmConfigurations.value).toEqual([configuration]);
  });

  it('aborts the previous initial request when the chat route changes', async () => {
    let firstCoreSignal: AbortSignal | undefined;

    apiMocks.get.mockImplementation(
      (path: string, options?: { signal?: AbortSignal }) => {
        if (path.endsWith('/settings')) return Promise.resolve(chatSettings());
        if (path === '/api/bff/chat-state/2') return Promise.resolve(chatState(2));
        if (path === '/api/bff/chat-state/1') {
          firstCoreSignal = options?.signal;
          return new Promise<ChatStatePayload>((_resolve, reject) => {
            firstCoreSignal?.addEventListener(
              'abort',
              () => reject(new DOMException('The operation was aborted.', 'AbortError')),
              { once: true }
            );
          });
        }
        return Promise.resolve(undefined);
      }
    );

    const { viewModel, router } = await mountViewModel();
    await vi.waitFor(() => expect(firstCoreSignal).toBeDefined());

    await router.replace('/chats/2');
    await vi.waitFor(() => expect(viewModel.chat.value?.id).toBe(2));

    expect(firstCoreSignal?.aborted).toBe(true);
    expect(viewModel.loaded.value).toBe(true);
  });

  it('aborts the pending settings request when the core request fails', async () => {
    let settingsSignal: AbortSignal | undefined;

    apiMocks.get.mockImplementation(
      (path: string, options?: { signal?: AbortSignal }) => {
        if (path === '/api/bff/chat-state/1/settings') {
          settingsSignal = options?.signal;
          return new Promise<ChatSettingsStatePayload>(() => undefined);
        }
        if (path === '/api/bff/chat-state/1') {
          return Promise.reject(
            Object.assign(new Error('Core request failed.'), { status: 400 })
          );
        }
        return Promise.resolve(undefined);
      }
    );

    const { viewModel } = await mountViewModel();

    await vi.waitFor(() => expect(settingsSignal?.aborted).toBe(true));
    expect(viewModel.loaded.value).toBe(true);
    expect(viewModel.loadError.value).toBe('Core request failed.');
  });

  it('ignores a late initial response for the previous chat', async () => {
    const coreResolvers = new Map<number, (payload: ChatStatePayload) => void>();

    apiMocks.get.mockImplementation((path: string) => {
      const match = path.match(/^\/api\/bff\/chat-state\/(\d+)$/u);
      if (match) {
        const id = Number(match[1]);
        return new Promise<ChatStatePayload>((resolve) => {
          coreResolvers.set(id, resolve);
        });
      }
      if (path.endsWith('/settings')) return Promise.resolve(chatSettings());
      return Promise.resolve(undefined);
    });

    const { viewModel, router } = await mountViewModel();
    await vi.waitFor(() => expect(coreResolvers.has(1)).toBe(true));

    await router.replace('/chats/2');
    await vi.waitFor(() => expect(coreResolvers.has(2)).toBe(true));

    coreResolvers.get(2)?.(chatState(2));
    await vi.waitFor(() => expect(viewModel.chat.value?.id).toBe(2));

    coreResolvers.get(1)?.(chatState(1));
    await flushPromises();

    expect(viewModel.chat.value?.id).toBe(2);
    expect(viewModel.loaded.value).toBe(true);
  });
});
