import { flushPromises, mount } from '@vue/test-utils';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
import { defineComponent, h, nextTick, ref } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  jsonApiList: vi.fn(),
}));

vi.mock('@/api/client', () => ({
  api: {
    get: apiMocks.get,
  },
}));

vi.mock('@/api/jsonApi', async () => {
  const actual = await vi.importActual<typeof import('@/api/jsonApi')>('@/api/jsonApi');
  return {
    ...actual,
    jsonApiList: apiMocks.jsonApiList,
  };
});

import ChatsIndexView from '@/views/ChatsIndexView.vue';
import { provideStackLayer } from '@/features/stack/useStackLayer';

describe('ChatsIndexView stack navigation', () => {
  beforeEach(() => {
    apiMocks.get.mockReset().mockImplementation(async (path: string) => {
      if (path.startsWith('/api/bff/chat-list?')) {
        return {
          chats: [],
          page: { number: 1, per_page: 20, total: 0, has_next: false },
          stats: { total_chats: 0, no_bot_chat_count: 0, no_bot_last_activity_at: null, bots: [] },
          idle_revision: 'revision-1',
        };
      }

      return undefined;
    });
    apiMocks.jsonApiList.mockResolvedValue({ data: [] });
    vi.stubGlobal(
      'matchMedia',
      vi.fn(() => ({
        matches: false,
        media: '',
        onchange: null,
        addListener: vi.fn(),
        removeListener: vi.fn(),
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
        dispatchEvent: vi.fn(),
      }))
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it.each([
    { sections: ['other'], headings: [] },
    { sections: ['unread', 'other'], headings: ['Unread 1', 'Other chats 1'] },
    { sections: ['working', 'other'], headings: ['Working chats 1', 'Other chats 1'] },
    { sections: ['unread'], headings: ['Unread 1'] },
    { sections: ['working'], headings: ['Working chats 1'] },
  ])('shows appropriate headings for $sections', async ({ sections, headings }) => {
    apiMocks.get.mockImplementation(async (path: string) => {
      if (!path.startsWith('/api/bff/chat-list?')) return undefined;
      const section = new URL(path, 'http://localhost').searchParams.get('section')!;
      const chats = sections.includes(section) ? [{
        id: ['unread', 'working', 'other'].indexOf(section) + 1,
        title: `${section} chat`,
        read_state: { is_unread: section === 'unread' },
        active_generation_message_id: section === 'working' ? 42 : null,
      }] : [];
      return {
        chats,
        page: { number: 1, per_page: 20, total: chats.length, has_next: false },
        idle_revision: 'revision-1',
      };
    });
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/chats', component: { template: '<div />' } }],
    });
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    await router.push('/chats');
    await router.isReady();
    const wrapper = mount(ChatsIndexView, {
      global: {
        plugins: [router, [VueQueryPlugin, { queryClient }]],
        stubs: {
          BotSelectorModal: true,
          ChatBotFiltersPanel: true,
          ChatListRow: true,
          ContinuationNav: true,
          InitialRoutePlaceholder: true,
          PullToRefresh: { template: '<div><slot /></div>' },
          StackToolbarTeleport: { template: '<div><slot /></div>' },
          SvgIcon: true,
        },
      },
    });

    try {
      await flushPromises();
      expect(wrapper.findAll('.chat-section').map((section) => section.attributes('data-section'))).toEqual(sections);
      expect(wrapper.findAll('chat-list-row-stub')).toHaveLength(sections.length);
      expect(wrapper.findAll('.chat-section__heading').map((heading) => heading.text())).toEqual(headings);
    } finally {
      wrapper.unmount();
      queryClient.clear();
    }
  });

  it('fully reloads the list when it becomes active after closing a chat', async () => {
    const active = ref(true);
    const presented = ref(true);
    const Host = defineComponent({
      setup() {
        provideStackLayer({
          active,
          presented,
          depth: ref(0),
          setReady: vi.fn(),
        });
        return () => h(ChatsIndexView);
      },
    });
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/chats', name: 'chats', component: { template: '<div />' } }],
    });
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    await router.push('/chats');
    await router.isReady();

    const wrapper = mount(Host, {
      global: {
        plugins: [router, [VueQueryPlugin, { queryClient }]],
        stubs: {
          BotSelectorModal: true,
          ChatBotFiltersPanel: true,
          ChatListRow: true,
          ContinuationNav: true,
          InitialRoutePlaceholder: true,
          PullToRefresh: { template: '<div><slot /></div>' },
          StackToolbarTeleport: { template: '<div><slot /></div>' },
          SvgIcon: true,
        },
      },
    });

    const fullListRequests = () =>
      apiMocks.get.mock.calls.filter(([path]) => String(path).startsWith('/api/bff/chat-list?'));

    await vi.waitFor(() => expect(fullListRequests()).toHaveLength(4));

    active.value = false;
    await nextTick();
    active.value = true;
    await nextTick();
    await flushPromises();

    await vi.waitFor(() => expect(fullListRequests()).toHaveLength(8));

    wrapper.unmount();
    queryClient.clear();
  });
});
