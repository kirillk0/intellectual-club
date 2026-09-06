import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
import { defineComponent, h, nextTick, ref } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

const apiMocks = vi.hoisted(() => ({ get: vi.fn(), jsonApiList: vi.fn() }));

vi.mock('@/api/client', () => ({ api: { get: apiMocks.get } }));
vi.mock('@/api/jsonApi', async () => ({
  ...(await vi.importActual<typeof import('@/api/jsonApi')>('@/api/jsonApi')),
  jsonApiList: apiMocks.jsonApiList,
}));

import ChatsIndexView from '@/views/ChatsIndexView.vue';
import { provideStackLayer } from '@/features/stack/useStackLayer';

const listPayload = (note = 'Old list') => ({
  chats: [{ id: 1, note, created_at: '2026-09-06T00:00:00Z', message_count: 0 }],
  page: { number: 1, per_page: 20, total: 1, has_next: false },
  idle_revision: note,
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

const listRequests = () => apiMocks.get.mock.calls.filter(([path]) => path.startsWith('/api/bff/chat-list?'));
const idleRequests = () => apiMocks.get.mock.calls.filter(([path]) => path.startsWith('/api/bff/chat-list/idle-state?'));

describe('chat list refresh after returning from the background', () => {
  let wrapper: VueWrapper;
  let queryClient: QueryClient;
  let visibility = 'visible';

  async function mountList(path = '/chats') {
    const active = ref(true);
    const Host = defineComponent({
      setup() {
        provideStackLayer({ active, presented: ref(true), depth: ref(0), setReady: vi.fn() });
        return () => h(ChatsIndexView);
      },
    });
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/chats', component: { template: '<div />' } }],
    });
    await router.push(path);
    queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    wrapper = mount(Host, {
      global: {
        plugins: [router, [VueQueryPlugin, { queryClient }]],
        stubs: {
          BotSelectorModal: true,
          ChatBotFiltersPanel: true,
          ChatListRow: { props: ['title'], template: '<div class="chat-row">{{ title }}</div>' },
          ContinuationNav: true,
          InitialRoutePlaceholder: true,
          StackToolbarTeleport: { template: '<div><slot /></div>' },
          SvgIcon: true,
        },
      },
    });
    await flushPromises();
    return active;
  }

  async function pull() {
    const surface = wrapper.get('.pull-to-refresh');
    await surface.trigger('touchstart', { touches: [{ clientX: 100, clientY: 100 }] });
    await surface.trigger('touchmove', { touches: [{ clientX: 100, clientY: 220 }] });
    expect(surface.classes()).toContain('pull-to-refresh--ready');
    await surface.trigger('touchend', { touches: [] });
    await flushPromises();
  }

  beforeEach(() => {
    vi.useFakeTimers();
    visibility = 'visible';
    vi.spyOn(document, 'visibilityState', 'get').mockImplementation(() => visibility as DocumentVisibilityState);
    vi.stubGlobal('matchMedia', vi.fn((media: string) => ({
      matches: true, media, addEventListener: vi.fn(), removeEventListener: vi.fn(),
    })));
    document.documentElement.scrollTop = 0;
    apiMocks.get.mockReset().mockImplementation(async (path: string) =>
      path.startsWith('/api/bff/chat-list?') ? listPayload() : undefined
    );
    apiMocks.jsonApiList.mockReset().mockResolvedValue({ data: [] });
  });

  afterEach(() => {
    wrapper?.unmount();
    queryClient?.clear();
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it('allows a pull during a background bot refetch and finishes without waiting for bots', async () => {
    await mountList();
    const bots = deferred<{ data: [] }>();
    apiMocks.jsonApiList.mockImplementation(() => bots.promise);
    visibility = 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
    visibility = 'visible';
    document.dispatchEvent(new Event('visibilitychange'));
    void queryClient.refetchQueries();
    await flushPromises();
    expect(queryClient.isFetching()).toBe(1);

    apiMocks.get.mockImplementation(async (path: string) =>
      path.startsWith('/api/bff/chat-list?') ? listPayload('Fresh list') : undefined
    );
    await pull();
    expect(listRequests()).toHaveLength(2);
    expect(wrapper.get('.chat-row').text()).toContain('Fresh list');
    await vi.advanceTimersByTimeAsync(400);
    expect(wrapper.get('.pull-to-refresh').classes()).toContain('pull-to-refresh--idle');
    expect(queryClient.isFetching()).toBe(1);

    await pull();
    expect(listRequests()).toHaveLength(3);
    bots.resolve({ data: [] });
    await flushPromises();
  });

  it('lets a pull replace a pending list load and ignores the obsolete response', async () => {
    const active = await mountList();
    const stale = deferred<ReturnType<typeof listPayload>>();
    apiMocks.get.mockImplementationOnce(() => stale.promise);
    active.value = false;
    await nextTick();
    active.value = true;
    await flushPromises();
    const pendingSignal = listRequests()[1][1].signal as AbortSignal;

    await pull();
    expect(listRequests()).toHaveLength(3);
    expect(pendingSignal.aborted).toBe(true);
    stale.resolve(listPayload('Obsolete response'));
    await flushPromises();
    expect(wrapper.get('.chat-row').text()).not.toContain('Obsolete response');
  });

  it('lets a pull replace a pending search', async () => {
    const stale = deferred<ReturnType<typeof listPayload>>();
    apiMocks.get.mockImplementation(async (path: string) =>
      path.startsWith('/api/bff/chat-list/search?') ? stale.promise : listPayload()
    );
    await mountList('/chats?q=test');
    const searchRequests = () => apiMocks.get.mock.calls.filter(([path]) => path.startsWith('/api/bff/chat-list/search?'));
    const pendingSignal = searchRequests()[0][1].signal as AbortSignal;
    apiMocks.get.mockResolvedValue(listPayload('Fresh search'));

    await pull();
    expect(searchRequests()).toHaveLength(2);
    expect(pendingSignal.aborted).toBe(true);
    expect(wrapper.get('.chat-row').text()).toContain('Fresh search');
    stale.resolve(listPayload('Obsolete search'));
    await flushPromises();
    expect(wrapper.get('.chat-row').text()).toContain('Fresh search');
  });

  it('keeps the wake-up probe alive across visibility, pageshow and focus events', async () => {
    await mountList();
    const probe = deferred<{ revision: string }>();
    apiMocks.get.mockImplementation(async (path: string) =>
      path.startsWith('/api/bff/chat-list/idle-state?') ? probe.promise : listPayload('Fresh list')
    );
    visibility = 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
    visibility = 'visible';
    document.dispatchEvent(new Event('visibilitychange'));
    const signal = idleRequests()[0][1].signal as AbortSignal;
    window.dispatchEvent(new Event('pageshow'));
    window.dispatchEvent(new Event('focus'));

    expect(signal.aborted).toBe(false);
    expect(idleRequests()).toHaveLength(1);
    probe.resolve({ revision: 'Fresh list' });
    await flushPromises();
    expect(wrapper.get('.chat-row').text()).toContain('Fresh list');
    expect(listRequests()).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(idleRequests()).toHaveLength(2);
  });

  it('refreshes immediately after a quick second background round trip', async () => {
    await mountList();
    window.dispatchEvent(new Event('focus'));
    await flushPromises();
    expect(idleRequests()).toHaveLength(1);
    visibility = 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
    await vi.advanceTimersByTimeAsync(100);
    visibility = 'visible';
    document.dispatchEvent(new Event('visibilitychange'));
    await flushPromises();
    expect(idleRequests()).toHaveLength(2);
  });
});
