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
  isHttpError: () => false,
}));

import type {
  ChatSettingsStatePayload,
  ChatStatePayload,
} from '@/features/chat/model/chatViewModel.shared';
import { useChatViewModel } from '@/features/chat/useChatViewModel';

type ChatViewModel = ReturnType<typeof useChatViewModel>;

const chatState = (id: number): ChatStatePayload => ({
  chat: {
    id,
    bot_id: null,
    llm_configuration_id: null,
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

const chatSettings = (): ChatSettingsStatePayload => ({
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
    llm_configurations: [],
    knowledge_blocks: [],
    tool_instances: [],
  },
});

let activeWrapper: VueWrapper | null = null;

async function mountViewModel(path = '/chats/1') {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/chats/:id', name: 'chat', component: { template: '<div />' } }],
  });
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
  return { viewModel, router };
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
    vi.unstubAllGlobals();
  });

  it('shows the chat after the core response while settings are still pending', async () => {
    let resolveSettings!: (payload: ChatSettingsStatePayload) => void;
    const settingsRequest = new Promise<ChatSettingsStatePayload>((resolve) => {
      resolveSettings = resolve;
    });

    apiMocks.get.mockImplementation((path: string) => {
      if (path === '/api/bff/chat-state/1/settings') return settingsRequest;
      if (path === '/api/bff/chat-state/1') return Promise.resolve(chatState(1));
      return Promise.resolve(undefined);
    });

    const { viewModel } = await mountViewModel();

    await vi.waitFor(() => expect(viewModel.loaded.value).toBe(true));
    expect(viewModel.chat.value?.id).toBe(1);
    expect(viewModel.loadError.value).toBe('');

    resolveSettings(chatSettings());
    await flushPromises();
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
