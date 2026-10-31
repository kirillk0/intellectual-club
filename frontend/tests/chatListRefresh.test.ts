import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
import { defineComponent, h, nextTick, ref } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

const apiMocks = vi.hoisted(() => ({ get: vi.fn(), jsonApiList: vi.fn() }));

vi.mock('@/api/client', async () => ({
  ...(await vi.importActual<typeof import('@/api/client')>('@/api/client')),
  api: { get: apiMocks.get },
}));
vi.mock('@/api/jsonApi', async () => ({
  ...(await vi.importActual<typeof import('@/api/jsonApi')>('@/api/jsonApi')),
  jsonApiList: apiMocks.jsonApiList,
}));

import ChatsIndexView from '@/views/ChatsIndexView.vue';
import { HttpError } from '@/api/client';
import type { ChatSummary } from '@/types/api';
import { provideStackLayer } from '@/features/stack/useStackLayer';
import { publishChatChange } from '@/features/chat/chatEvents';

const listPayload = (note = 'Old list') => ({
  chats: [{ id: 1, note, created_at: '2026-09-06T00:00:00Z', message_count: 0 }],
  page: { number: 1, per_page: 20, total: 1, has_next: false },
  idle_revision: note,
});

const SECTIONS = ['drafts', 'unread', 'working', 'other'];
type SectionPageInfo = { number: number; per_page: number; total: number | null; has_next: boolean; next_cursor?: string | null };
type SectionResult = { chats: ChatSummary[]; page?: SectionPageInfo };
const searchCursor = (section: string, page: number) => `opaque:${section}/${page}+=`;

// Mirrors the grouped search contract: unique rows plus ordered IDs and a page per requested section.
function groupedSearchPayload(
  path: string,
  sectionResult: (section: string, page: number, cursor: string | null) => SectionResult,
  extra: Record<string, unknown> = {}
) {
  const params = new URL(path, 'http://localhost').searchParams;
  const rows = new Map<number, ChatSummary>();
  const sections = Object.fromEntries((params.get('sections') || '').split(',').map((section) => {
    const number = Number(params.get(`page_${section}`) || 1);
    const result = sectionResult(section, number, params.get(`after_${section}`));
    for (const chat of result.chats) if (!rows.has(chat.id)) rows.set(chat.id, chat);
    const page = {
      number, per_page: Number(params.get('per_page') || 20), has_next: false,
      next_cursor: result.page?.has_next ? searchCursor(section, number + 1) : null,
      ...result.page, total: null,
    };
    return [section, { ids: result.chats.map((chat) => chat.id), page }];
  }));
  return { chats: [...rows.values()], sections, next_read_state_expiry: null, text_search: true, ...extra };
}

const searchPayload = (note: string, extra: Record<string, unknown> = {}) => groupedSearchPayload(
  `/api/bff/chat-list/search?sections=${SECTIONS.join(',')}`,
  (section) => ({ chats: section === 'other' ? [listPayload(note).chats[0] as ChatSummary] : [] }),
  extra
);

const isSearchPath = (path: string) => path.startsWith('/api/bff/chat-list/search?');

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

const listRequests = () => apiMocks.get.mock.calls.filter(([path]) => path.startsWith('/api/bff/chat-list?'));
const idleRequests = () => apiMocks.get.mock.calls.filter(([path]) => path.startsWith('/api/bff/chat-list/idle-state?'));
const searchRequests = () => apiMocks.get.mock.calls.filter(([path]) => isSearchPath(path));
const searchParams = (call: unknown[]) => new URL(String(call[0]), 'http://localhost').searchParams;

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
    expect(listRequests()).toHaveLength(12);
    expect(wrapper.get('.chat-row').text()).toContain('Fresh list');
    await vi.advanceTimersByTimeAsync(400);
    expect(wrapper.get('.pull-to-refresh').classes()).toContain('pull-to-refresh--idle');
    expect(queryClient.isFetching()).toBe(1);

    await pull();
    expect(listRequests()).toHaveLength(16);
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
    const pendingSignal = listRequests()[4][1].signal as AbortSignal;

    await pull();
    expect(listRequests()).toHaveLength(12);
    expect(pendingSignal.aborted).toBe(true);
    stale.resolve(listPayload('Obsolete response'));
    await flushPromises();
    expect(wrapper.get('.chat-row').text()).not.toContain('Obsolete response');
  });

  it('lets a pull replace a pending search', async () => {
    const stale = deferred<ReturnType<typeof searchPayload>>();
    apiMocks.get.mockImplementation(async (path: string) =>
      isSearchPath(path) ? stale.promise : listPayload()
    );
    await mountList('/chats?q=test');
    const pendingSignal = searchRequests()[0][1].signal as AbortSignal;
    apiMocks.get.mockImplementation(async (path: string) =>
      isSearchPath(path) ? searchPayload('Fresh search') : listPayload()
    );

    await pull();
    expect(searchRequests()).toHaveLength(2);
    expect(pendingSignal.aborted).toBe(true);
    expect(wrapper.get('.chat-row').text()).toContain('Fresh search');
    stale.resolve(searchPayload('Obsolete search'));
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
    expect(idleRequests()).toHaveLength(4);
    probe.resolve({ revision: 'Fresh list' });
    await flushPromises();
    expect(wrapper.get('.chat-row').text()).toContain('Fresh list');
    expect(listRequests()).toHaveLength(8);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(idleRequests()).toHaveLength(8);
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
    expect(idleRequests()).toHaveLength(4);
    expect(listRequests()).toHaveLength(8);
    expect(wrapper.get('.chat-row').text()).toContain('Working changed remotely');
  });

  it('refreshes immediately after a quick second background round trip', async () => {
    await mountList();
    window.dispatchEvent(new Event('focus'));
    await flushPromises();
    expect(idleRequests()).toHaveLength(4);
    visibility = 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
    await vi.advanceTimersByTimeAsync(100);
    visibility = 'visible';
    document.dispatchEvent(new Event('visibilitychange'));
    await flushPromises();
    expect(idleRequests()).toHaveLength(8);
  });

  function sectionChat(id: number, section: string, extra: Partial<ChatSummary> = {}): ChatSummary & { read_state: NonNullable<ChatSummary['read_state']> } {
    return {
      id, note: `${section} ${id}`, bot_id: null, bot_name: '', created_at: '2026-09-06T00:00:00Z', last_activity_at: '2026-09-06T00:00:00Z',
      active_generation_message_id: section === 'working' ? id * 10 : null,
      has_draft: section === 'drafts', draft_updated_at: section === 'drafts' ? '2026-09-07T00:00:00Z' : null,
      read_state: { activity_revision: 8, read_revision: section === 'unread' ? 7 : 8, manual_unread: false, snoozed_until: null, state_version: 2, has_unread: section === 'unread', is_unread: section === 'unread', is_snoozed: false },
      ...extra,
    };
  }

  function sectionPage(section: string, page: number) {
    const baseId = { drafts: 400, unread: 100, working: 200, other: 300 }[section]!;
    return {
      chats: [sectionChat(baseId + page, section)],
      page: { number: page, per_page: 20, total: 45, has_next: page < 3 },
    };
  }

  function searchSectionPage(section: string, page: number, cursor: string | null) {
    // Select rows by the opaque cursor, not the displayed page number.
    const rowPage = cursor == null ? 1 : [2, 3].find((number) => cursor === searchCursor(section, number))!;
    const result = sectionPage(section, rowPage);
    return { ...result, page: { ...result.page, number: page } };
  }

  function sectionButton(section: string, label: 'Next' | 'Previous') {
    return wrapper.get(`[data-section="${section}"]`).findAll('.pagination button').find((button) => button.text() === label)!;
  }

  async function turnSearchPage(section: string, label: 'Next' | 'Previous' = 'Next') {
    await sectionButton(section, label).trigger('click');
    await flushPromises();
  }

  function sectionPayload(path: string) {
    const params = new URL(path, 'http://localhost').searchParams;
    return sectionPage(params.get('section') || 'other', Number(params.get('page') || 1));
  }

  it.each(['/chats', '/chats?q=needle'])('hides empty sections in %s', async (path) => {
    const rows = (section: string | null) => ({ chats: section === 'working' ? [sectionChat(1, 'working')] : [] });
    apiMocks.get.mockImplementation(async (url: string) => isSearchPath(url)
      ? groupedSearchPayload(url, rows)
      : rows(new URL(url, 'http://localhost').searchParams.get('section')));
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
    expect(listRequests()).toHaveLength(4);
    expect(listRequests().map(([path]) => new URL(path, 'http://localhost').searchParams.get('section'))).toEqual(['drafts', 'unread', 'working', 'other']);
    for (const [path] of listRequests()) expect(new URL(path, 'http://localhost').searchParams.get('bot')).toBe('5');
    const unread = wrapper.get('[data-section="unread"]');
    expect(wrapper.findAll('.chat-row')).toHaveLength(4);
    await unread.findAll('button').find((button) => button.text() === 'Next')!.trigger('click');
    await flushPromises();
    const pages = listRequests().slice(-4).map(([path]) => new URL(path, 'http://localhost').searchParams.get('page'));
    expect(pages).toEqual(['1', '2', '1', '1']);
    expect(unread.text()).toContain('Page 2 of 3');
    expect(wrapper.get('[data-section="other"]').text()).toContain('Page 1 of 3');
  });

  it('uses independent cursor histories for next and previous without an exact search total', async () => {
    apiMocks.get.mockImplementation(async (path: string) =>
      isSearchPath(path) ? groupedSearchPayload(path, searchSectionPage) : sectionPayload(path));
    await mountList('/chats?q=needle');
    expect(searchRequests()).toHaveLength(1);
    expect(wrapper.findAll('.chat-row')).toHaveLength(4);
    expect(wrapper.findAll('.chat-section__heading .muted')).toHaveLength(0);
    expect(wrapper.findAll('.pagination .muted').map((label) => label.text())).toEqual(SECTIONS.map(() => 'Page 1'));
    expect(SECTIONS.map((section) => searchParams(searchRequests()[0]).has(`after_${section}`))).toEqual(SECTIONS.map(() => false));

    await turnSearchPage('working');
    expect(searchRequests()).toHaveLength(2);
    expect(SECTIONS.map((section) => searchParams(searchRequests()[1]).get(`page_${section}`))).toEqual(['1', '1', '2', '1']);
    expect(SECTIONS.map((section) => searchParams(searchRequests()[1]).get(`after_${section}`))).toEqual([null, null, searchCursor('working', 2), null]);
    expect(wrapper.get('[data-section="working"] .pagination .muted').text()).toBe('Page 2');
    expect(wrapper.get('[data-section="working"]').text()).toContain('working 202');
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 101');

    await turnSearchPage('unread');
    await turnSearchPage('working');
    expect(sectionButton('working', 'Next').attributes('disabled')).toBeDefined();
    expect(wrapper.get('[data-section="working"] .pagination .muted').text()).toBe('Page 3');
    await turnSearchPage('working', 'Previous');
    let params = searchParams(searchRequests().at(-1)!);
    expect(SECTIONS.map((section) => params.get(`page_${section}`))).toEqual(['1', '2', '2', '1']);
    expect(SECTIONS.map((section) => params.get(`after_${section}`))).toEqual([null, searchCursor('unread', 2), searchCursor('working', 2), null]);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 102');

    await turnSearchPage('working', 'Previous');
    params = searchParams(searchRequests().at(-1)!);
    expect(params.get('page_working')).toBe('1');
    expect(params.has('after_working')).toBe(false);
    expect(params.get('after_unread')).toBe(searchCursor('unread', 2));
    expect(sectionButton('working', 'Previous').attributes('disabled')).toBeDefined();
    for (const call of searchRequests()) expect(searchParams(call).get('q')).toBe('needle');
    expect(searchRequests()).toHaveLength(6);
  });

  it('resets all expired search cursors and retries once from the first pages', async () => {
    apiMocks.get.mockImplementation(async (path: string) =>
      isSearchPath(path) ? groupedSearchPayload(path, searchSectionPage) : sectionPayload(path));
    await mountList('/chats?q=needle');
    await turnSearchPage('working');
    await turnSearchPage('unread');
    const invalid = new HttpError({ status: 422, statusText: 'Unprocessable Entity', bodyText: '', bodyJson: { code: 'invalid_cursor' } });
    apiMocks.get.mockRejectedValueOnce(invalid);
    await turnSearchPage('working', 'Previous');
    expect(searchRequests()).toHaveLength(5);
    const retry = searchParams(searchRequests().at(-1)!);
    for (const section of SECTIONS) {
      expect(retry.get(`page_${section}`)).toBe('1');
      expect(retry.has(`after_${section}`)).toBe(false);
      expect(wrapper.get(`[data-section="${section}"] .pagination .muted`).text()).toBe('Page 1');
    }
    expect(wrapper.text()).not.toContain('Failed to search chats.');
    const banner = searchRequests()[3][1].showErrorBanner as (error: unknown) => boolean;
    expect(banner(invalid)).toBe(false);
  });

  it('does not loop if the first-page retry also reports an invalid cursor', async () => {
    const invalid = new HttpError({ status: 422, statusText: 'Unprocessable Entity', bodyText: '', bodyJson: { code: 'invalid_cursor' } });
    apiMocks.get.mockImplementation(async (path: string) => {
      if (isSearchPath(path)) throw invalid;
      return sectionPayload(path);
    });
    vi.spyOn(console, 'error').mockImplementation(() => undefined);
    await mountList('/chats?q=needle');
    expect(searchRequests()).toHaveLength(2);
    expect(wrapper.text()).toContain('Failed to search chats.');
  });

  it('keeps an emptied current search page navigable after deletion without clamping or refetching page one', async () => {
    let deleted = false;
    apiMocks.get.mockImplementation(async (path: string) => {
      if (!isSearchPath(path)) return sectionPayload(path);
      return groupedSearchPayload(path, (section, page, cursor) => section === 'working' && page === 2 && deleted
        ? { chats: [], page: { number: 2, per_page: 20, total: null, has_next: false, next_cursor: null } }
        : searchSectionPage(section, page, cursor));
    });
    await mountList('/chats?q=needle');
    await turnSearchPage('working');
    deleted = true;
    publishChatChange({ operation: 'delete', id: 202 });
    await flushPromises();

    expect(searchRequests()).toHaveLength(3);
    expect(searchParams(searchRequests()[2]).get('page_working')).toBe('2');
    expect(searchParams(searchRequests()[2]).get('after_working')).toBe(searchCursor('working', 2));
    expect(wrapper.get('[data-section="working"]').findAll('.chat-row')).toHaveLength(0);
    expect(wrapper.get('[data-section="working"] .pagination .muted').text()).toBe('Page 2');
    expect(sectionButton('working', 'Previous').attributes('disabled')).toBeUndefined();
    expect(sectionButton('working', 'Next').attributes('disabled')).toBeDefined();

    await turnSearchPage('working', 'Previous');
    expect(searchRequests()).toHaveLength(4);
    expect(searchParams(searchRequests()[3]).has('after_working')).toBe(false);
    expect(wrapper.get('[data-section="working"]').text()).toContain('working 201');
  });

  it.each(['term', 'bot', 'per_page'])('resets all search cursors and rejects pending results when changing %s', async (filter) => {
    apiMocks.get.mockImplementation(async (path: string) =>
      isSearchPath(path) ? groupedSearchPayload(path, searchSectionPage) : sectionPayload(path));
    await mountList('/chats?q=needle');
    await turnSearchPage('working');
    await turnSearchPage('unread');
    const stale = deferred<ReturnType<typeof groupedSearchPayload>>();
    apiMocks.get.mockImplementationOnce(() => stale.promise);
    await turnSearchPage('working');
    const staleCall = searchRequests().at(-1)!;

    if (filter === 'term') {
      await wrapper.get('input[type="search"]').setValue('different');
    } else if (filter === 'bot') {
      wrapper.findComponent({ name: 'ChatBotFiltersPanel' }).vm.$emit('select-filter', 'none');
      await nextTick();
    } else {
      // The page size is currently internal; exercise the same reactive input as the request builder.
      (wrapper.findComponent(ChatsIndexView).vm.$ as unknown as { setupState: { perPage: number } }).setupState.perPage = 10;
      await nextTick();
    }
    expect((staleCall[1].signal as AbortSignal).aborted).toBe(true);
    stale.resolve(groupedSearchPayload(String(staleCall[0]), (section, page, cursor) => {
      const result = searchSectionPage(section, page, cursor);
      result.chats.forEach((chat) => { chat.note = 'Obsolete search'; });
      return result;
    }));
    await flushPromises();
    expect(wrapper.text()).not.toContain('Obsolete search');
    if (filter === 'term') {
      expect(searchRequests()).toHaveLength(4);
      await vi.advanceTimersByTimeAsync(600);
      await flushPromises();
    }

    expect(searchRequests()).toHaveLength(5);
    const params = searchParams(searchRequests().at(-1)!);
    expect(SECTIONS.map((section) => params.get(`page_${section}`))).toEqual(SECTIONS.map(() => '1'));
    expect(SECTIONS.map((section) => params.has(`after_${section}`))).toEqual(SECTIONS.map(() => false));
    expect(params.get('q')).toBe(filter === 'term' ? 'different' : 'needle');
    expect(params.get('bot')).toBe(filter === 'bot' ? 'none' : null);
    expect(params.get('per_page')).toBe(filter === 'per_page' ? '10' : '20');
    expect(wrapper.get('[data-section="working"] .pagination .muted').text()).toBe('Page 1');
    expect(sectionButton('working', 'Previous').attributes('disabled')).toBeDefined();
  });

  it.each(['pull', 'idle'])('repeats the current search cursor rather than the next cursor on %s refresh', async (refresh) => {
    apiMocks.get.mockImplementation(async (path: string) => {
      if (path.startsWith('/api/bff/chat-list/idle-state?')) return { revision: 'changed' };
      return isSearchPath(path)
        ? groupedSearchPayload(path, (section, page, cursor) => section === 'other' ? searchSectionPage(section, page, cursor) : { chats: [] })
        : listPayload();
    });
    await mountList('/chats?q=needle');
    await turnSearchPage('other');
    if (refresh === 'pull') {
      await pull();
      // Let the gesture's click suppression expire before using the pager again.
      await vi.advanceTimersByTimeAsync(500);
    } else {
      await vi.advanceTimersByTimeAsync(30_000);
      await flushPromises();
    }
    expect(searchRequests()).toHaveLength(3);
    const params = searchParams(searchRequests()[2]);
    expect(params.get('page_other')).toBe('2');
    expect(params.get('after_other')).toBe(searchCursor('other', 2));
    expect(wrapper.get('[data-section="other"] .pagination .muted').text()).toBe('Page 2');
    await turnSearchPage('other');
    expect(searchParams(searchRequests()[3]).get('after_other')).toBe(searchCursor('other', 3));
  });

  it.each(['Next', 'Previous'] as const)('retains the current search page and cursor history when %s fails so it can be retried', async (direction) => {
    vi.spyOn(console, 'error').mockImplementation(() => undefined);
    let fail = false;
    apiMocks.get.mockImplementation(async (path: string) => {
      if (!isSearchPath(path)) return sectionPayload(path);
      if (fail) throw new Error('Offline');
      return groupedSearchPayload(path, searchSectionPage);
    });
    await mountList('/chats?q=needle');
    await turnSearchPage('working');
    fail = true;
    await turnSearchPage('working', direction);
    expect(wrapper.text()).toContain('Failed to search chats.');
    expect(wrapper.get('[data-section="working"]').text()).toContain('working 202');
    expect(wrapper.get('[data-section="working"] .pagination .muted').text()).toBe('Page 2');
    expect(sectionButton('working', direction).attributes('disabled')).toBeUndefined();

    fail = false;
    await turnSearchPage('working', direction);
    const page = direction === 'Next' ? 3 : 1;
    expect(searchParams(searchRequests()[3]).get('after_working')).toBe(page === 1 ? null : searchCursor('working', page));
    expect(searchRequests()[3][0]).toBe(searchRequests()[2][0]);
    expect(wrapper.get('[data-section="working"] .pagination .muted').text()).toBe(`Page ${page}`);
    expect(wrapper.text()).not.toContain('Failed to search chats.');
  });

  it('lets a refresh complete a pending cursor transition without applying its stale response', async () => {
    apiMocks.get.mockImplementation(async (path: string) =>
      isSearchPath(path) ? groupedSearchPayload(path, searchSectionPage) : sectionPayload(path));
    await mountList('/chats?q=needle');
    const stale = deferred<ReturnType<typeof groupedSearchPayload>>();
    apiMocks.get.mockImplementationOnce(() => stale.promise);
    await turnSearchPage('working');
    const pending = searchRequests()[1];
    expect(wrapper.get('[data-section="working"] .pagination .muted').text()).toBe('Page 1');
    await pull();
    expect((pending[1].signal as AbortSignal).aborted).toBe(true);
    expect(searchRequests()[2][0]).toBe(pending[0]);
    expect(wrapper.get('[data-section="working"] .pagination .muted').text()).toBe('Page 2');
    stale.resolve(groupedSearchPayload(String(pending[0]), () => ({ chats: [] })));
    await flushPromises();
    expect(wrapper.get('[data-section="working"]').text()).toContain('working 202');
    expect(sectionButton('working', 'Next').attributes('disabled')).toBeUndefined();
  });

  it('ignores an aborted idle search response and retains the current cursor on wake', async () => {
    apiMocks.get.mockImplementation(async (path: string) => {
      if (path.startsWith('/api/bff/chat-list/idle-state?')) return { revision: 'changed' };
      return isSearchPath(path)
        ? groupedSearchPayload(path, (section, page, cursor) => section === 'other' ? searchSectionPage(section, page, cursor) : { chats: [] })
        : listPayload();
    });
    await mountList('/chats?q=needle');
    await turnSearchPage('other');
    const stale = deferred<ReturnType<typeof groupedSearchPayload>>();
    const respond = apiMocks.get.getMockImplementation()!;
    apiMocks.get.mockImplementation((path: string) => isSearchPath(path) ? stale.promise : respond(path));
    await vi.advanceTimersByTimeAsync(30_000);
    const pending = searchRequests()[2];
    visibility = 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
    expect((pending[1].signal as AbortSignal).aborted).toBe(true);
    stale.resolve(groupedSearchPayload(String(pending[0]), () => ({ chats: [] })));
    await flushPromises();
    expect(wrapper.get('[data-section="other"]').text()).toContain('other 302');
    expect(sectionButton('other', 'Next').attributes('disabled')).toBeUndefined();
    apiMocks.get.mockImplementation(respond);
    visibility = 'visible';
    document.dispatchEvent(new Event('visibilitychange'));
    await flushPromises();
    expect(searchRequests()[3][0]).toBe(pending[0]);
  });

  it('searches every section with a single grouped request', async () => {
    apiMocks.get.mockImplementation(async (path: string) => {
      if (!isSearchPath(path)) return sectionPayload(path);
      return groupedSearchPayload(path, (section, page) => {
        const result = sectionPage(section, page);
        result.chats.forEach((chat) => { chat.bot_id = 5; });
        return result;
      });
    });
    await mountList('/chats?q=needle&bot=5');
    await vi.advanceTimersByTimeAsync(1_000);

    expect(searchRequests()).toHaveLength(1);
    const params = searchParams(searchRequests()[0]);
    expect(params.get('q')).toBe('needle');
    expect(params.get('sections')).toBe('drafts,unread,working,other');
    expect(params.get('per_page')).toBe('20');
    expect(params.get('bot')).toBe('5');
    expect(params.has('section')).toBe(false);
    expect(params.has('page')).toBe(false);
    expect(SECTIONS.map((section) => params.get(`page_${section}`))).toEqual(['1', '1', '1', '1']);
    expect(wrapper.findAll('[data-section]').map((section) => section.attributes('data-section')))
      .toEqual(['drafts', 'unread', 'working', 'other']);
  });

  it('starts searching from three characters after the debounce', async () => {
    await mountList();
    const input = wrapper.get('input[type="search"]');

    await input.setValue('ab');
    await vi.advanceTimersByTimeAsync(1_000);
    expect(searchRequests()).toHaveLength(0);

    apiMocks.get.mockImplementation(async (path: string) =>
      isSearchPath(path) ? searchPayload('Found chat') : listPayload());
    await input.setValue('abc');
    await vi.advanceTimersByTimeAsync(599);
    expect(searchRequests()).toHaveLength(0);
    await vi.advanceTimersByTimeAsync(1);
    await flushPromises();

    expect(searchRequests()).toHaveLength(1);
    expect(searchParams(searchRequests()[0]).get('q')).toBe('abc');
    expect(wrapper.get('.chat-row').text()).toContain('Found chat');
  });

  it('explains when the term only matched chat metadata', async () => {
    let textSearch = false;
    apiMocks.get.mockImplementation(async (path: string) =>
      isSearchPath(path) ? searchPayload('Meta match', { text_search: textSearch }) : listPayload());
    await mountList('/chats?q=ab%20cd');

    expect(wrapper.get('.chat-search-hint').text()).toContain('enter at least 3 letters or digits in a row');
    expect(wrapper.get('.chat-row').text()).toContain('Meta match');

    textSearch = true;
    await wrapper.get('input[type="search"]').setValue('abc');
    await vi.advanceTimersByTimeAsync(600);
    await flushPromises();
    expect(wrapper.find('.chat-search-hint').exists()).toBe(false);
  });

  it('shows a search timeout inline without the global error banner', async () => {
    const timeout = new HttpError({
      status: 503,
      statusText: 'Service Unavailable',
      bodyText: '',
      bodyJson: { error: 'Search timed out.', code: 'search_timeout' },
    });
    apiMocks.get.mockImplementation(async (path: string) => {
      if (isSearchPath(path)) throw timeout;
      return listPayload();
    });
    await mountList('/chats?q=needle');

    expect(searchRequests()).toHaveLength(1);
    expect(wrapper.text()).toContain('Search took too long. Try a more specific query.');
    expect(wrapper.text()).not.toContain('Failed to search chats.');
    expect(wrapper.text()).not.toContain('No matches found.');
    expect(wrapper.findAll('.chat-row')).toHaveLength(0);
    const showErrorBanner = searchRequests()[0][1].showErrorBanner as (error: unknown) => boolean;
    expect(showErrorBanner(timeout)).toBe(false);
    expect(showErrorBanner(new HttpError({ status: 500, statusText: 'Error', bodyText: '', bodyJson: null }))).toBe(true);
  });

  it('refreshes search results with one silent grouped request from the idle probe', async () => {
    apiMocks.get.mockImplementation(async (path: string) => {
      if (path.startsWith('/api/bff/chat-list/idle-state?')) return { revision: 'changed' };
      return isSearchPath(path) ? searchPayload('Old search') : listPayload();
    });
    await mountList('/chats?q=needle');
    expect(searchRequests()).toHaveLength(1);
    apiMocks.get.mockImplementation(async (path: string) => {
      if (path.startsWith('/api/bff/chat-list/idle-state?')) return { revision: 'changed' };
      return isSearchPath(path) ? searchPayload('Fresh search') : listPayload();
    });

    await vi.advanceTimersByTimeAsync(30_000);
    await flushPromises();

    expect(searchRequests()).toHaveLength(2);
    expect(searchRequests()[1][1]).toMatchObject({ showErrorBanner: false });
    expect(wrapper.text()).not.toContain('Searching...');
    expect(wrapper.get('.chat-row').text()).toContain('Fresh search');
  });

  it.each(['/chats', '/chats?q=needle'])('keeps drafts first without mixing independent inbox pages in %s', async (route) => {
    const shared = sectionChat(12, 'unread', { has_draft: true, draft_updated_at: '2026-09-07T00:00:00Z' });
    const draftOnly = sectionChat(13, 'other', { has_draft: true, draft_updated_at: '2026-09-08T00:00:00Z' });
    const ordinary = sectionChat(14, 'other');
    const sectionRows = (section: string | null) => {
      const rows = section === 'drafts' ? [draftOnly, shared] : section === 'unread' ? [shared] : section === 'other' ? [ordinary] : [];
      return { chats: rows, page: { number: 1, per_page: 20, total: rows.length, has_next: false } };
    };
    apiMocks.get.mockImplementation(async (path: string) => isSearchPath(path)
      ? groupedSearchPayload(path, sectionRows)
      : sectionRows(new URL(path, 'http://localhost').searchParams.get('section')));
    await mountList(route);
    expect(wrapper.findAll('[data-section]').map((section) => section.attributes('data-section'))).toEqual(['drafts', 'unread', 'other']);
    const drafts = wrapper.get('[data-section="drafts"]');
    expect(drafts.findAll('.chat-row').map((row) => row.text())).toEqual([expect.stringContaining('other 13'), expect.stringContaining('unread 12')]);
    expect(wrapper.get('[data-section="unread"]').findAll('.chat-row')).toHaveLength(1);
    expect(wrapper.get('[data-section="other"]').text()).toContain('other 14');
    expect(wrapper.get('[data-section="other"]').text()).not.toContain('other 13');
  });

  it('preserves each search section order despite draft overlap and regroups the newest read state', async () => {
    const shared = sectionChat(12, 'unread', { has_draft: true });
    const first = sectionChat(10, 'unread');
    const draftOnly = sectionChat(13, 'other', { has_draft: true });
    const ordinary = sectionChat(14, 'other');
    const stale = sectionChat(15, 'unread', { has_draft: true });
    const moved = sectionChat(15, 'other', { has_draft: true });
    moved.read_state.state_version = 3;
    apiMocks.get.mockImplementation(async (path: string) => isSearchPath(path)
      ? groupedSearchPayload(path, (section) => ({ chats: {
        drafts: [shared, moved, draftOnly], unread: [first, shared, stale], other: [ordinary],
      }[section] || [] }), { chats: [shared, stale, draftOnly, first, ordinary, moved] })
      : listPayload());
    await mountList('/chats?q=needle');
    const notes = (section: string) => wrapper.get(`[data-section="${section}"]`).findAll('.chat-row').map((row) => row.text());
    expect(notes('drafts')).toEqual(['unread 12', 'other 15', 'other 13'].map((note) => expect.stringContaining(note)));
    expect(notes('unread')).toEqual(['unread 10', 'unread 12'].map((note) => expect.stringContaining(note)));
    expect(notes('other')).toEqual(['other 14', 'other 15'].map((note) => expect.stringContaining(note)));
  });

  it('persists the independent drafts page and removes the section after clearing the last draft', async () => {
    apiMocks.get.mockImplementation(async (path: string) => sectionPayload(path));
    await mountList('/chats?draftsPage=2&page=2');
    expect(wrapper.get('[data-section="drafts"]').text()).toContain('drafts 402');
    await wrapper.get('[data-section="drafts"]').findAll('button').find((button) => button.text() === 'Previous')!.trigger('click');
    await flushPromises();
    expect(listRequests().slice(-4).map(([path]) => new URL(path, 'http://localhost').searchParams.get('page'))).toEqual(['1', '1', '1', '2']);
    expect(window.location.search).not.toContain('draftsPage=');
    apiMocks.get.mockImplementation(async (path: string) => {
      const payload = sectionPayload(path);
      if (new URL(path, 'http://localhost').searchParams.get('section') === 'drafts') return { ...payload, chats: [], page: { number: 1, per_page: 20, total: 0, has_next: false } };
      return payload;
    });
    await pull();
    expect(wrapper.find('[data-section="drafts"]').exists()).toBe(false);
    expect(wrapper.get('[data-section="other"]').text()).toContain('other 302');
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
    expect(listRequests()).toHaveLength(8);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 1');
    expect(wrapper.find('[data-section="other"]').exists()).toBe(false);
    await vi.advanceTimersByTimeAsync(2_000);
    expect(listRequests()).toHaveLength(8);
    wrapper.unmount();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(listRequests()).toHaveLength(8);
  });

  it('refreshes an expired snooze after foregrounding even when the idle probe returns no changes', async () => {
    const chat = sectionChat(1, 'other');
    chat.read_state = { ...chat.read_state, manual_unread: true, is_snoozed: true, snoozed_until: new Date(Date.now() + 500).toISOString() };
    apiMocks.get.mockResolvedValue({ chats: [chat] });
    await mountList();
    visibility = 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
    await vi.advanceTimersByTimeAsync(1_000);
    expect(listRequests()).toHaveLength(4);
    apiMocks.get.mockImplementation(async (path: string) => path.startsWith('/api/bff/chat-list?') ? { chats: [sectionChat(1, 'unread')] } : undefined);
    visibility = 'visible';
    document.dispatchEvent(new Event('visibilitychange'));
    window.dispatchEvent(new Event('focus'));
    window.dispatchEvent(new Event('pageshow'));
    await flushPromises();
    await vi.advanceTimersByTimeAsync(100);
    expect(listRequests()).toHaveLength(8);
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
    expect(listRequests()).toHaveLength(8);
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
    expect(listRequests()).toHaveLength(8);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 99');
    await vi.advanceTimersByTimeAsync(2_000);
    expect(listRequests()).toHaveLength(8);
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
    expect(listRequests()).toHaveLength(8);
    expect(listRequests().slice(-4).map(([path]) => new URL(path, 'http://localhost').searchParams.get('page'))).toEqual(['1', '1', '2', '2']);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 101');
    expect(wrapper.get('[data-section="working"]').text()).toContain('working 202');
    expect(wrapper.get('[data-section="other"]').text()).toContain('other 302');
  });

});
