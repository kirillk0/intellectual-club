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
import type { ChatSummary } from '@/types/api';
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
    expect(listRequests()).toHaveLength(9);
    expect(wrapper.get('.chat-row').text()).toContain('Fresh list');
    await vi.advanceTimersByTimeAsync(400);
    expect(wrapper.get('.pull-to-refresh').classes()).toContain('pull-to-refresh--idle');
    expect(queryClient.isFetching()).toBe(1);

    await pull();
    expect(listRequests()).toHaveLength(12);
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
    const pendingSignal = listRequests()[3][1].signal as AbortSignal;

    await pull();
    expect(listRequests()).toHaveLength(9);
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
    expect(searchRequests()).toHaveLength(6);
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
    expect(idleRequests()).toHaveLength(3);
    probe.resolve({ revision: 'Fresh list' });
    await flushPromises();
    expect(wrapper.get('.chat-row').text()).toContain('Fresh list');
    expect(listRequests()).toHaveLength(6);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(idleRequests()).toHaveLength(6);
  });

  it('refreshes when only the working section changes on another device', async () => {
    await mountList();
    apiMocks.get.mockImplementation(async (path: string) => {
      const url = new URL(path, 'https://example.test');
      if (url.pathname.endsWith('/idle-state')) return url.searchParams.get('section') === 'working' ? { revision: 'working-changed' } : undefined;
      return listPayload('Working changed remotely');
    });
    await vi.advanceTimersByTimeAsync(30_000);
    await flushPromises();
    expect(idleRequests()).toHaveLength(3);
    expect(listRequests()).toHaveLength(6);
    expect(wrapper.get('.chat-row').text()).toContain('Working changed remotely');
  });

  it('refreshes immediately after a quick second background round trip', async () => {
    await mountList();
    window.dispatchEvent(new Event('focus'));
    await flushPromises();
    expect(idleRequests()).toHaveLength(3);
    visibility = 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
    await vi.advanceTimersByTimeAsync(100);
    visibility = 'visible';
    document.dispatchEvent(new Event('visibilitychange'));
    await flushPromises();
    expect(idleRequests()).toHaveLength(6);
  });

  function sectionChat(id: number, section: string, extra: Partial<ChatSummary> = {}): ChatSummary & { read_state: NonNullable<ChatSummary['read_state']> } {
    return {
      id, note: `${section} ${id}`, bot_id: null, bot_name: '', created_at: '2026-09-06T00:00:00Z', last_activity_at: '2026-09-06T00:00:00Z',
      active_generation_message_id: section === 'working' ? id * 10 : null,
      read_state: { activity_revision: 8, read_revision: section === 'unread' ? 7 : 8, manual_unread: false, snoozed_until: null, state_version: 2, has_unread: section === 'unread', is_unread: section === 'unread', is_snoozed: false },
      ...extra,
    };
  }

  function sectionPayload(path: string) {
    const params = new URL(path, 'http://localhost').searchParams;
    const section = params.get('section') || 'other';
    const page = Number(params.get('page') || 1);
    const baseId = { unread: 100, working: 200, other: 300 }[section]!;
    return {
      chats: [sectionChat(baseId + page, section)],
      page: { number: page, per_page: 20, total: 45, has_next: page < 3 },
    };
  }

  it.each(['/chats', '/chats?q=needle'])('hides empty sections in %s', async (path) => {
    apiMocks.get.mockImplementation(async (url: string) => {
      const section = new URL(url, 'http://localhost').searchParams.get('section');
      return { chats: section === 'working' ? [sectionChat(1, 'working')] : [] };
    });
    await mountList(path);
    expect(wrapper.findAll('[data-section]').map((section) => section.attributes('data-section'))).toEqual(['working']);
    expect(wrapper.text()).not.toContain('No chats in this section.');
  });

  it('keeps the overall empty state without empty section headings', async () => {
    apiMocks.get.mockResolvedValue({ chats: [] });
    await mountList();
    expect(wrapper.findAll('[data-section]')).toHaveLength(0);
    expect(wrapper.text()).toContain('No chats yet.');
  });

  it('hides sections whose loaded rows do not match the active filter', async () => {
    apiMocks.get.mockImplementation(async (path: string) => sectionPayload(path));
    await mountList('/chats?bot=5');
    expect(wrapper.findAll('[data-section]')).toHaveLength(0);
    expect(wrapper.text()).toContain('No chats match the current filters.');
  });

  it('requests all sections independently and changes only the selected section page', async () => {
    vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
    apiMocks.get.mockImplementation(async (path: string) => {
      const payload = sectionPayload(path);
      payload.chats.forEach((chat) => { chat.bot_id = 5; });
      return payload;
    });
    await mountList('/chats?bot=5');
    expect(listRequests()).toHaveLength(3);
    expect(listRequests().map(([path]) => new URL(path, 'http://localhost').searchParams.get('section'))).toEqual(['unread', 'working', 'other']);
    for (const [path] of listRequests()) expect(new URL(path, 'http://localhost').searchParams.get('bot')).toBe('5');
    const unread = wrapper.get('[data-section="unread"]');
    expect(wrapper.findAll('.chat-row')).toHaveLength(3);
    await unread.findAll('button').find((button) => button.text() === 'Next')!.trigger('click');
    await flushPromises();
    const pages = listRequests().slice(-3).map(([path]) => new URL(path, 'http://localhost').searchParams.get('page'));
    expect(pages).toEqual(['2', '1', '1']);
    expect(unread.text()).toContain('Page 2 of 3');
    expect(wrapper.get('[data-section="other"]').text()).toContain('Page 1 of 3');
  });

  it('paginates search sections across the full result set and preserves the query', async () => {
    apiMocks.get.mockImplementation(async (path: string) => sectionPayload(path));
    await mountList('/chats?q=needle');
    const searchRequests = () => apiMocks.get.mock.calls.filter(([path]) => path.startsWith('/api/bff/chat-list/search?'));
    expect(searchRequests()).toHaveLength(3);
    expect(wrapper.findAll('.chat-row')).toHaveLength(3);
    await wrapper.get('[data-section="working"]').findAll('button').find((button) => button.text() === 'Next')!.trigger('click');
    await flushPromises();
    expect(searchRequests().slice(-3).map(([path]) => new URL(path, 'http://localhost').searchParams.get('page'))).toEqual(['1', '2', '1']);
    for (const [path] of searchRequests()) expect(new URL(path, 'http://localhost').searchParams.get('q')).toBe('needle');
    expect(wrapper.get('[data-section="working"]').text()).toContain('working 202');
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 101');
  });

  it('deduplicates rows moved during a section batch using the newer read state', async () => {
    apiMocks.get.mockImplementation(async (path: string) => {
      const section = new URL(path, 'http://localhost').searchParams.get('section');
      const chat = sectionChat(1, section === 'unread' ? 'unread' : 'other');
      if (section === 'unread') chat.read_state.state_version = 3;
      return { chats: section === 'working' ? [] : [chat] };
    });
    await mountList();
    expect(wrapper.findAll('.chat-row')).toHaveLength(1);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 1');
    expect(wrapper.find('[data-section="other"]').exists()).toBe(false);
  });

  it('wakes a snoozed row once at its deadline and removes timers on unmount', async () => {
    const until = new Date(Date.now() + 1_000).toISOString();
    const chat = sectionChat(1, 'other');
    chat.read_state = { ...chat.read_state, manual_unread: true, has_unread: true, is_snoozed: true, snoozed_until: until };
    apiMocks.get.mockResolvedValue({ chats: [chat] });
    await mountList();
    apiMocks.get.mockResolvedValue({ chats: [sectionChat(1, 'unread')] });
    await vi.advanceTimersByTimeAsync(1_100);
    await flushPromises();
    expect(listRequests()).toHaveLength(6);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 1');
    expect(wrapper.find('[data-section="other"]').exists()).toBe(false);
    await vi.advanceTimersByTimeAsync(2_000);
    expect(listRequests()).toHaveLength(6);
    wrapper.unmount();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(listRequests()).toHaveLength(6);
  });

  it('refreshes an expired snooze after foregrounding even when the idle probe returns no changes', async () => {
    const chat = sectionChat(1, 'other');
    chat.read_state = { ...chat.read_state, manual_unread: true, is_snoozed: true, snoozed_until: new Date(Date.now() + 500).toISOString() };
    apiMocks.get.mockResolvedValue({ chats: [chat] });
    await mountList();
    visibility = 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
    await vi.advanceTimersByTimeAsync(1_000);
    expect(listRequests()).toHaveLength(3);
    apiMocks.get.mockImplementation(async (path: string) => path.startsWith('/api/bff/chat-list?') ? { chats: [sectionChat(1, 'unread')] } : undefined);
    visibility = 'visible';
    document.dispatchEvent(new Event('visibilitychange'));
    window.dispatchEvent(new Event('focus'));
    window.dispatchEvent(new Event('pageshow'));
    await flushPromises();
    await vi.advanceTimersByTimeAsync(100);
    expect(listRequests()).toHaveLength(6);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 1');
  });

  it('refreshes all sections on generation completion without synthesizing a done badge', async () => {
    const active = sectionChat(1, 'working');
    let finished = false;
    apiMocks.get.mockImplementation(async (path: string) => {
      if (path.startsWith('/api/bff/chat-list/generation-state?')) {
        finished = true;
        return { chat_generations: [], active_message_ids: [] };
      }
      return { chats: [finished ? sectionChat(1, 'unread', { last_message_status: 'error' }) : active] };
    });
    await mountList();
    await vi.advanceTimersByTimeAsync(1_500);
    await flushPromises();
    expect(listRequests()).toHaveLength(6);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 1');
    expect(wrapper.find('[data-section="working"]').exists()).toBe(false);
  });


  it('uses the server deadline for snoozed rows outside the loaded pages', async () => {
    const expiry = new Date(Date.now() + 1_000).toISOString();
    apiMocks.get.mockResolvedValue({ chats: [], next_read_state_expiry: expiry });
    await mountList();
    apiMocks.get.mockResolvedValue({ chats: [sectionChat(99, 'unread')], next_read_state_expiry: null });
    await vi.advanceTimersByTimeAsync(1_100);
    await flushPromises();
    expect(listRequests()).toHaveLength(6);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 99');
    await vi.advanceTimersByTimeAsync(2_000);
    expect(listRequests()).toHaveLength(6);
  });

  it('clamps an emptied section page without resetting the other section pages', async () => {
    apiMocks.get.mockImplementation(async (path: string) => {
      const payload = sectionPayload(path);
      const params = new URL(path, 'http://localhost').searchParams;
      if (params.get('section') === 'unread') {
        payload.page.total = 20;
        payload.page.has_next = false;
        if (params.get('page') === '2') payload.chats = [];
      }
      return payload;
    });
    await mountList('/chats?unreadPage=2&workingPage=2&page=2');
    expect(listRequests()).toHaveLength(6);
    expect(listRequests().slice(-3).map(([path]) => new URL(path, 'http://localhost').searchParams.get('page'))).toEqual(['1', '2', '2']);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 101');
    expect(wrapper.get('[data-section="working"]').text()).toContain('working 202');
    expect(wrapper.get('[data-section="other"]').text()).toContain('other 302');
  });

});
