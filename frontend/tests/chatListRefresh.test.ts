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
  ...groupedListRows([{ id: 1, note, created_at: '2026-09-06T00:00:00Z', message_count: 0 } as ChatSummary]),
  idle_revision: note,
});

const SECTIONS = ['drafts', 'unread', 'working', 'other'];
type SectionPageInfo = { number: number; per_page: number; total: number | null; has_next: boolean };
type SectionResult = { chats: ChatSummary[]; page?: SectionPageInfo };

// Mirrors the grouped list contract: unique rows plus ordered IDs and a page per requested section.
function groupedListPayload(path: string, sectionResult: (section: string, page: number) => SectionResult, extra: Record<string, unknown> = {}) {
  const params = new URL(path, 'http://localhost').searchParams;
  const rows = new Map<number, ChatSummary>();
  const sections = Object.fromEntries((params.get('sections') || '').split(',').map((section) => {
    const number = Number(params.get(`page_${section}`) || 1);
    const result = sectionResult(section, number);
    for (const chat of result.chats) if (!rows.has(chat.id)) rows.set(chat.id, chat);
    const page = {
      number, per_page: Number(params.get('per_page') || 20), has_next: false,
      ...result.page, total: result.page?.total ?? result.chats.length,
    };
    return [section, { ids: result.chats.map((chat) => chat.id), page }];
  }));
  return { chats: [...rows.values()], sections, next_read_state_expiry: null, ...extra };
}

type SearchHit = {
  message_id: number; chat_id: number; role: 'user' | 'assistant' | null; created_at: string | null; active: boolean; snippet: string | null;
};
type SearchPayload = {
  chats: ChatSummary[]; notes: number[]; hits: SearchHit[]; next_cursor: string | null; text_search: boolean; terms: string[];
  next_read_state_expiry: string | null;
};

// Mirrors the search contract: note matches, message hits newest first and a cursor for the next page.
function searchResults(partial: Partial<SearchPayload> & { chats?: ChatSummary[] } = {}): SearchPayload {
  return { chats: [], notes: [], hits: [], next_cursor: null, text_search: true, terms: ['needle'], next_read_state_expiry: null, ...partial };
}

function hit(messageId: number, chatId: number, extra: Partial<SearchHit> = {}): SearchHit {
  return { message_id: messageId, chat_id: chatId, role: 'user', created_at: '2026-09-06T00:00:00Z', active: true, snippet: `needle ${messageId}`, ...extra };
}

function groupedListRows(chats: ChatSummary[], extra: Record<string, unknown> = {}) {
  return groupedListPayload(`/api/bff/chat-list?sections=${SECTIONS.join(',')}`, (section) => ({ chats: chats.filter((chat) => {
    if (section === 'drafts') return chat.has_draft;
    return section === (chat.read_state?.is_unread ? 'unread' : chat.active_generation_message_id ? 'working' : 'other');
  }) }), extra);
}

const searchPayload = (note: string, extra: Partial<SearchPayload> = {}) =>
  searchResults({ chats: [listPayload(note).chats[0] as ChatSummary], notes: [1], ...extra });

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
    expect(listRequests()).toHaveLength(3);
    expect(wrapper.get('.chat-row').text()).toContain('Fresh list');
    await vi.advanceTimersByTimeAsync(400);
    expect(wrapper.get('.pull-to-refresh').classes()).toContain('pull-to-refresh--idle');
    expect(queryClient.isFetching()).toBe(1);

    await pull();
    expect(listRequests()).toHaveLength(4);
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
    expect(idleRequests()).toHaveLength(1);
    probe.resolve({ revision: 'Fresh list' });
    await flushPromises();
    expect(wrapper.get('.chat-row').text()).toContain('Fresh list');
    expect(listRequests()).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(idleRequests()).toHaveLength(2);
  });

  it('refreshes when only the working section changes on another device', async () => {
    await mountList();
    apiMocks.get.mockImplementation(async (path: string) => {
      const url = new URL(path, 'https://example.test');
      if (url.pathname.endsWith('/idle-state')) return { revision: 'working-changed' };
      return listPayload('Working changed remotely');
    });
    await vi.advanceTimersByTimeAsync(30_000);
    await flushPromises();
    expect(idleRequests()).toHaveLength(1);
    expect(listRequests()).toHaveLength(2);
    expect(wrapper.get('.chat-row').text()).toContain('Working changed remotely');
  });

  it('probes all displayed pages with one revision and skips a reload on an unchanged response', async () => {
    apiMocks.get.mockImplementation(async (path: string) => path.startsWith('/api/bff/chat-list?')
      ? { ...sectionPayload(path), idle_revision: 'all-sections-revision' } : undefined);
    await mountList('/chats?draftsPage=2&unreadPage=2&workingPage=3&page=2&bot=5');
    expect(listRequests()).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(30_000);
    await flushPromises();
    expect(idleRequests()).toHaveLength(1);
    const params = searchParams(idleRequests()[0]);
    expect(params.get('sections')).toBe(SECTIONS.join(','));
    expect(params.get('revision')).toBe('all-sections-revision');
    expect(params.get('bot')).toBe('5');
    expect(params.get('per_page')).toBe('20');
    expect(SECTIONS.map((section) => params.get(`page_${section}`))).toEqual(['2', '2', '3', '2']);
    expect(params.has('section')).toBe(false);
    expect(listRequests()).toHaveLength(1);
  });

  it('retains the last applied revision when a changed idle response cannot be loaded', async () => {
    await mountList();
    vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    apiMocks.get.mockImplementation(async (path: string) => {
      if (path.startsWith('/api/bff/chat-list/idle-state?')) return { revision: 'not-applied' };
      throw new Error('Offline');
    });
    await vi.advanceTimersByTimeAsync(30_000);
    await flushPromises();
    expect(listRequests()).toHaveLength(2);
    expect(wrapper.get('.chat-row').text()).toContain('Old list');
    await vi.advanceTimersByTimeAsync(30_000);
    await flushPromises();
    expect(idleRequests()).toHaveLength(2);
    expect(searchParams(idleRequests()[1]).get('revision')).toBe('Old list');
    expect(listRequests()).toHaveLength(3);
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

  function sectionPayload(path: string) {
    return groupedListPayload(path, sectionPage);
  }

  it('hides empty sections', async () => {
    const rows = (section: string | null) => ({ chats: section === 'working' ? [sectionChat(1, 'working')] : [] });
    apiMocks.get.mockImplementation(async (url: string) => groupedListPayload(url, rows));
    await mountList('/chats');
    expect(wrapper.findAll('[data-section]').map((section) => section.attributes('data-section'))).toEqual(['working']);
    expect(wrapper.text()).not.toContain('No chats in this section.');
  });

  it.each([
    ['notes', searchResults({ chats: [sectionChat(1, 'other')], notes: [1] })],
    ['messages', searchResults({ chats: [sectionChat(1, 'other')], hits: [hit(10, 1)] })],
  ])('shows only the %s search section when the other one is empty', async (section, payload) => {
    apiMocks.get.mockImplementation(async (url: string) => isSearchPath(url) ? payload : listPayload());
    await mountList('/chats?q=needle');
    expect(wrapper.findAll('[data-section]').map((element) => element.attributes('data-section'))).toEqual([section]);
    expect(wrapper.findAll('.chat-row')).toHaveLength(1);
    expect(wrapper.find('.pagination').exists()).toBe(false);
    expect(wrapper.text()).not.toContain('No matches found.');
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

  it('requests all sections once and changes only the selected section page', async () => {
    vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
    apiMocks.get.mockImplementation(async (path: string) => {
      const payload = sectionPayload(path);
      payload.chats.forEach((chat) => { chat.bot_id = 5; });
      return payload;
    });
    await mountList('/chats?bot=5');
    expect(listRequests()).toHaveLength(1);
    expect(searchParams(listRequests()[0]).get('sections')).toBe('drafts,unread,working,other');
    expect(searchParams(listRequests()[0]).has('section')).toBe(false);
    expect(searchParams(listRequests()[0]).has('page')).toBe(false);
    for (const [path] of listRequests()) expect(new URL(path, 'http://localhost').searchParams.get('bot')).toBe('5');
    const unread = wrapper.get('[data-section="unread"]');
    expect(wrapper.findAll('.chat-row')).toHaveLength(4);
    await unread.findAll('button').find((button) => button.text() === 'Next')!.trigger('click');
    await flushPromises();
    expect(listRequests()).toHaveLength(2);
    const pages = SECTIONS.map((section) => searchParams(listRequests().at(-1)!).get(`page_${section}`));
    expect(pages).toEqual(['1', '2', '1', '1']);
    expect(unread.text()).toContain('Page 2 of 3');
    expect(wrapper.get('[data-section="other"]').text()).toContain('Page 1 of 3');
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

    expect(wrapper.get('.chat-search-hint').text()).toContain('at least 3 letters or digits in a row');
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

  it('refreshes search results with one silent request from the idle probe', async () => {
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
    expect(searchParams(searchRequests()[1]).has('after')).toBe(false);
    expect(searchParams(searchRequests()[1]).get('limit')).toBe('30');
    expect(wrapper.text()).not.toContain('Searching...');
    expect(wrapper.get('.chat-row').text()).toContain('Fresh search');
  });

  function searchChat(id: number, note: string) {
    return sectionChat(id, 'other', { note });
  }

  const hitLinks = () => wrapper.findAll('.chat-search-hit__link').map((link) => link.attributes('href'));

  it('sends the query, exact flag, bot and page size in one request without section parameters', async () => {
    apiMocks.get.mockImplementation(async (path: string) => isSearchPath(path)
      ? searchResults({ chats: [searchChat(1, 'Alpha')], hits: [hit(10, 1)] })
      : listPayload());
    await mountList('/chats?q=needle&bot=5&exact=1');
    await vi.advanceTimersByTimeAsync(1_000);

    expect(searchRequests()).toHaveLength(1);
    const params = searchParams(searchRequests()[0]);
    expect(params.get('q')).toBe('needle');
    expect(params.get('exact')).toBe('1');
    expect(params.get('bot')).toBe('5');
    expect(params.get('limit')).toBe('30');
    for (const key of ['after', 'sections', 'section', 'page', 'per_page', ...SECTIONS.flatMap((section) => [`page_${section}`, `after_${section}`])]) {
      expect(params.has(key)).toBe(false);
    }
    expect(wrapper.get('.chat-search__exact').attributes('aria-pressed')).toBe('true');
  });

  it('groups adjacent hits under one chat header, highlights terms and links to the focused message', async () => {
    const alpha = searchChat(1, 'Alpha');
    const beta = searchChat(2, 'Beta');
    const gamma = searchChat(3, 'Gamma note');
    apiMocks.get.mockImplementation(async (path: string) => isSearchPath(path)
      ? searchResults({
        chats: [gamma, alpha, beta],
        notes: [3],
        terms: ['needle', 'fine'],
        hits: [
          hit(10, 1, { snippet: 'A fine NEEDLE in Alpha' }),
          hit(9, 1, { role: 'assistant', active: false, snippet: 'needle again' }),
          hit(8, 2, { snippet: 'needle in Beta' }),
          hit(7, 1, { snippet: 'older needle in Alpha' }),
        ],
      })
      : listPayload());
    await mountList('/chats?q=needle%20fine');

    expect(wrapper.findAll('[data-section]').map((section) => section.attributes('data-section'))).toEqual(['notes', 'messages']);
    expect(wrapper.get('[data-section="notes"]').findAll('.chat-row').map((row) => row.text())).toEqual([expect.stringContaining('Gamma note')]);
    expect(wrapper.get('[data-section="notes"]').findAll('.chat-search-hit')).toHaveLength(0);

    const groups = wrapper.get('[data-section="messages"]').findAll('.chat-list-entry');
    expect(groups.map((group) => group.get('.chat-row').text())).toEqual(['Alpha', 'Beta', 'Alpha'].map((note) => expect.stringContaining(note)));
    expect(groups.map((group) => group.findAll('.chat-search-hit').length)).toEqual([2, 1, 1]);

    const first = groups[0].findAll('.chat-search-hit');
    expect(first[0].findAll('mark').map((mark) => mark.text())).toEqual(['fine', 'NEEDLE']);
    expect(first[0].text()).toContain('You');
    expect(first[0].find('.badge').exists()).toBe(false);
    expect(first[1].text()).toContain('Assistant');
    expect(first[1].get('.badge').text()).toBe('Inactive branch');

    expect(hitLinks()).toEqual([
      '/chats/1?focusMessage=10',
      '/chats/1?focusMessage=9&focusInactive=1',
      '/chats/2?focusMessage=8',
      '/chats/1?focusMessage=7',
    ]);
    expect(wrapper.find('.chat-search-more').exists()).toBe(false);
    expect(wrapper.text()).not.toContain('No matches found.');
  });

  it('loads more hits with the cursor and continues the last group', async () => {
    const alpha = searchChat(1, 'Alpha');
    const beta = searchChat(2, 'Beta');
    apiMocks.get.mockImplementation(async (path: string) => {
      if (!isSearchPath(path)) return listPayload();
      const after = searchParams([path]).get('after');
      if (after === 'cursor-1') return searchResults({ chats: [alpha, beta], hits: [hit(8, 1), hit(7, 2)], next_cursor: null });
      return searchResults({ chats: [alpha], hits: [hit(10, 1), hit(9, 1)], next_cursor: 'cursor-1' });
    });
    await mountList('/chats?q=needle');
    expect(wrapper.get('.chat-search-more button').text()).toBe('Show more');

    await wrapper.get('.chat-search-more button').trigger('click');
    await flushPromises();

    expect(searchRequests()).toHaveLength(2);
    expect(searchParams(searchRequests()[1]).get('after')).toBe('cursor-1');
    expect(searchParams(searchRequests()[1]).get('q')).toBe('needle');
    const groups = wrapper.get('[data-section="messages"]').findAll('.chat-list-entry');
    expect(groups.map((group) => group.get('.chat-row').text())).toEqual(['Alpha', 'Beta'].map((note) => expect.stringContaining(note)));
    expect(groups.map((group) => group.findAll('.chat-search-hit').length)).toEqual([3, 1]);
    expect(wrapper.find('.chat-search-more').exists()).toBe(false);

    // A silent refresh re-reads every loaded hit at once.
    apiMocks.get.mockImplementation(async (path: string) => {
      if (path.startsWith('/api/bff/chat-list/idle-state?')) return { revision: 'changed' };
      return isSearchPath(path) ? searchResults({ chats: [alpha], hits: [hit(10, 1)] }) : listPayload();
    });
    await vi.advanceTimersByTimeAsync(30_000);
    await flushPromises();
    expect(searchRequests()).toHaveLength(3);
    expect(searchParams(searchRequests()[2]).has('after')).toBe(false);
    expect(searchParams(searchRequests()[2]).get('limit')).toBe('30');
    expect(wrapper.findAll('.chat-search-hit')).toHaveLength(1);
  });

  it('restarts from the newest hits when a show-more cursor has expired', async () => {
    const invalid = new HttpError({ status: 422, statusText: 'Unprocessable Entity', bodyText: '', bodyJson: { code: 'invalid_cursor' } });
    apiMocks.get.mockImplementation(async (path: string) => {
      if (!isSearchPath(path)) return listPayload();
      if (searchParams([path]).has('after')) throw invalid;
      return searchResults({ chats: [searchChat(1, 'Alpha')], hits: [hit(10, 1)], next_cursor: 'stale' });
    });
    await mountList('/chats?q=needle');
    await wrapper.get('.chat-search-more button').trigger('click');
    await flushPromises();

    expect(searchRequests()).toHaveLength(3);
    expect(searchParams(searchRequests()[1]).get('after')).toBe('stale');
    expect(searchParams(searchRequests()[2]).has('after')).toBe(false);
    expect(wrapper.text()).not.toContain('Failed to search chats.');
    expect(wrapper.findAll('.chat-search-hit')).toHaveLength(1);
    const banner = searchRequests()[1][1].showErrorBanner as (error: unknown) => boolean;
    expect(banner(invalid)).toBe(false);
  });

  it('keeps loaded hits and shows the error inline when show more fails', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => undefined);
    apiMocks.get.mockImplementation(async (path: string) => {
      if (!isSearchPath(path)) return listPayload();
      if (searchParams([path]).has('after')) throw new Error('Offline');
      return searchResults({ chats: [searchChat(1, 'Alpha')], hits: [hit(10, 1)], next_cursor: 'cursor-1' });
    });
    await mountList('/chats?q=needle');
    await wrapper.get('.chat-search-more button').trigger('click');
    await flushPromises();

    expect(wrapper.text()).toContain('Failed to search chats.');
    expect(wrapper.findAll('.chat-search-hit')).toHaveLength(1);
    expect(wrapper.get('.chat-search-more button').attributes('disabled')).toBeUndefined();
  });

  it.each(['term', 'bot', 'exact'])('restarts without a cursor and rejects pending results when changing %s', async (filter) => {
    apiMocks.get.mockImplementation(async (path: string) => isSearchPath(path)
      ? searchResults({ chats: [searchChat(1, 'Alpha')], hits: [hit(10, 1)], next_cursor: 'cursor-1' })
      : listPayload());
    await mountList('/chats?q=needle');
    const stale = deferred<SearchPayload>();
    apiMocks.get.mockImplementationOnce(() => stale.promise);
    await wrapper.get('.chat-search-more button').trigger('click');
    const staleCall = searchRequests().at(-1)!;
    expect(searchParams(staleCall).get('after')).toBe('cursor-1');

    if (filter === 'term') {
      await wrapper.get('input[type="search"]').setValue('different');
    } else if (filter === 'bot') {
      wrapper.findComponent({ name: 'ChatBotFiltersPanel' }).vm.$emit('select-filter', 'none');
      await nextTick();
    } else {
      await wrapper.get('.chat-search__exact').trigger('click');
    }
    expect((staleCall[1].signal as AbortSignal).aborted).toBe(true);
    stale.resolve(searchResults({ chats: [searchChat(9, 'Obsolete search')], hits: [hit(1, 9)] }));
    await flushPromises();
    expect(wrapper.text()).not.toContain('Obsolete search');
    if (filter === 'term') {
      expect(searchRequests()).toHaveLength(2);
      await vi.advanceTimersByTimeAsync(600);
      await flushPromises();
    }

    expect(searchRequests()).toHaveLength(3);
    const params = searchParams(searchRequests().at(-1)!);
    expect(params.has('after')).toBe(false);
    expect(params.get('q')).toBe(filter === 'term' ? 'different' : 'needle');
    expect(params.get('bot')).toBe(filter === 'bot' ? 'none' : null);
    expect(params.get('exact')).toBe(filter === 'exact' ? '1' : null);
    if (filter === 'exact') {
      expect(window.location.search).toContain('exact=1');
      expect(wrapper.get('.chat-search__exact').attributes('aria-pressed')).toBe('true');
    }
  });

  it('keeps drafts first without mixing independent inbox pages', async () => {
    const shared = sectionChat(12, 'unread', { has_draft: true, draft_updated_at: '2026-09-07T00:00:00Z' });
    const draftOnly = sectionChat(13, 'other', { has_draft: true, draft_updated_at: '2026-09-08T00:00:00Z' });
    const ordinary = sectionChat(14, 'other');
    const sectionRows = (section: string | null) => {
      const rows = section === 'drafts' ? [draftOnly, shared] : section === 'unread' ? [shared] : section === 'other' ? [ordinary] : [];
      return { chats: rows, page: { number: 1, per_page: 20, total: rows.length, has_next: false } };
    };
    apiMocks.get.mockImplementation(async (path: string) => groupedListPayload(path, sectionRows));
    await mountList('/chats');
    expect(wrapper.findAll('[data-section]').map((section) => section.attributes('data-section'))).toEqual(['drafts', 'unread', 'other']);
    const drafts = wrapper.get('[data-section="drafts"]');
    expect(drafts.findAll('.chat-row').map((row) => row.text())).toEqual([expect.stringContaining('other 13'), expect.stringContaining('unread 12')]);
    expect(wrapper.get('[data-section="unread"]').findAll('.chat-row')).toHaveLength(1);
    expect(wrapper.get('[data-section="other"]').text()).toContain('other 14');
    expect(wrapper.get('[data-section="other"]').text()).not.toContain('other 13');
  });

  it('preserves section order despite draft overlap and regroups the newest read state', async () => {
    const shared = sectionChat(12, 'unread', { has_draft: true });
    const first = sectionChat(10, 'unread');
    const draftOnly = sectionChat(13, 'other', { has_draft: true });
    const ordinary = sectionChat(14, 'other');
    const stale = sectionChat(15, 'unread', { has_draft: true });
    const moved = sectionChat(15, 'other', { has_draft: true });
    moved.read_state.state_version = 3;
    apiMocks.get.mockImplementation(async (path: string) => groupedListPayload(path,
      (section) => ({ chats: {
        drafts: [shared, moved, draftOnly], unread: [first, shared, stale], other: [ordinary],
      }[section] || [] }), { chats: [shared, stale, draftOnly, first, ordinary, moved] }));
    await mountList('/chats');
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
    expect(SECTIONS.map((section) => searchParams(listRequests().at(-1)!).get(`page_${section}`))).toEqual(['1', '1', '1', '2']);
    expect(window.location.search).not.toContain('draftsPage=');
    apiMocks.get.mockImplementation(async (path: string) => {
      return groupedListPayload(path, (section, page) => section === 'drafts'
        ? { chats: [], page: { number: 1, per_page: 20, total: 0, has_next: false } }
        : sectionPage(section, page));
    });
    await pull();
    expect(wrapper.find('[data-section="drafts"]').exists()).toBe(false);
    expect(wrapper.get('[data-section="other"]').text()).toContain('other 302');
  });

  it('deduplicates repeated rows using the newer read state', async () => {
    const older = sectionChat(1, 'other');
    const newer = sectionChat(1, 'unread');
    newer.read_state.state_version = 3;
    apiMocks.get.mockResolvedValue(groupedListRows([older, newer]));
    await mountList();
    expect(wrapper.findAll('.chat-row')).toHaveLength(1);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 1');
    expect(wrapper.find('[data-section="other"]').exists()).toBe(false);
  });

  it('wakes a snoozed row once at its deadline and removes timers on unmount', async () => {
    const until = new Date(Date.now() + 1_000).toISOString();
    const chat = sectionChat(1, 'other');
    chat.read_state = { ...chat.read_state, manual_unread: true, has_unread: true, is_snoozed: true, snoozed_until: until };
    apiMocks.get.mockResolvedValue(groupedListRows([chat]));
    await mountList();
    apiMocks.get.mockResolvedValue(groupedListRows([sectionChat(1, 'unread')]));
    await vi.advanceTimersByTimeAsync(1_100);
    await flushPromises();
    expect(listRequests()).toHaveLength(2);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 1');
    expect(wrapper.find('[data-section="other"]').exists()).toBe(false);
    await vi.advanceTimersByTimeAsync(2_000);
    expect(listRequests()).toHaveLength(2);
    wrapper.unmount();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(listRequests()).toHaveLength(2);
  });

  it('refreshes an expired snooze after foregrounding even when the idle probe returns no changes', async () => {
    const chat = sectionChat(1, 'other');
    chat.read_state = { ...chat.read_state, manual_unread: true, is_snoozed: true, snoozed_until: new Date(Date.now() + 500).toISOString() };
    apiMocks.get.mockResolvedValue(groupedListRows([chat]));
    await mountList();
    visibility = 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
    await vi.advanceTimersByTimeAsync(1_000);
    expect(listRequests()).toHaveLength(1);
    apiMocks.get.mockImplementation(async (path: string) => path.startsWith('/api/bff/chat-list?') ? groupedListRows([sectionChat(1, 'unread')]) : undefined);
    visibility = 'visible';
    document.dispatchEvent(new Event('visibilitychange'));
    window.dispatchEvent(new Event('focus'));
    window.dispatchEvent(new Event('pageshow'));
    await flushPromises();
    await vi.advanceTimersByTimeAsync(100);
    expect(listRequests()).toHaveLength(2);
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
      return groupedListRows([finished ? sectionChat(1, 'unread', { last_message_status: 'error' }) : active]);
    });
    await mountList();
    await vi.advanceTimersByTimeAsync(1_500);
    await flushPromises();
    expect(listRequests()).toHaveLength(2);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 1');
    expect(wrapper.find('[data-section="working"]').exists()).toBe(false);
  });


  it('uses the server deadline for snoozed rows outside the loaded pages', async () => {
    const expiry = new Date(Date.now() + 1_000).toISOString();
    apiMocks.get.mockResolvedValue(groupedListRows([], { next_read_state_expiry: expiry }));
    await mountList();
    apiMocks.get.mockResolvedValue(groupedListRows([sectionChat(99, 'unread')], { next_read_state_expiry: null }));
    await vi.advanceTimersByTimeAsync(1_100);
    await flushPromises();
    expect(listRequests()).toHaveLength(2);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 99');
    await vi.advanceTimersByTimeAsync(2_000);
    expect(listRequests()).toHaveLength(2);
  });

  it('clamps an emptied section page without resetting the other section pages', async () => {
    apiMocks.get.mockImplementation(async (path: string) => groupedListPayload(path, (section, page) => {
      const payload = sectionPage(section, page);
      if (section === 'unread') {
        payload.page.total = 20;
        payload.page.has_next = false;
        if (page === 2) payload.chats = [];
      }
      return payload;
    }));
    await mountList('/chats?unreadPage=2&workingPage=2&page=2');
    expect(listRequests()).toHaveLength(2);
    expect(SECTIONS.map((section) => searchParams(listRequests().at(-1)!).get(`page_${section}`))).toEqual(['1', '1', '2', '2']);
    expect(wrapper.get('[data-section="unread"]').text()).toContain('unread 101');
    expect(wrapper.get('[data-section="working"]').text()).toContain('working 202');
    expect(wrapper.get('[data-section="other"]').text()).toContain('other 302');
  });

});
