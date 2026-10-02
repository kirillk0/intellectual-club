import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
import { defineComponent, h, ref } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  jsonApiList: vi.fn(),
  jsonApiUpdate: vi.fn(),
  jsonApiDelete: vi.fn(),
}));

vi.mock('@/api/client', () => ({ api: { get: apiMocks.get } }));
vi.mock('@/api/jsonApi', async () => ({
  ...(await vi.importActual<typeof import('@/api/jsonApi')>('@/api/jsonApi')),
  jsonApiList: apiMocks.jsonApiList,
  jsonApiUpdate: apiMocks.jsonApiUpdate,
  jsonApiDelete: apiMocks.jsonApiDelete,
}));

import ChatsIndexView from '@/views/ChatsIndexView.vue';
import { provideStackLayer } from '@/features/stack/useStackLayer';

const chatRow = (id: number, note: string, canEdit: boolean) => ({
  id,
  note,
  bot_id: null,
  bot_name: '',
  created_at: '2026-09-06T00:00:00Z',
  last_activity_at: '2026-09-06T00:00:00Z',
  message_count: 0,
  can_edit: canEdit,
});

const listPayload = () => ({
  chats: [chatRow(1, 'Own chat', true), chatRow(2, 'Shared chat', false)],
  page: { number: 1, per_page: 20, total: 2, has_next: false },
  idle_revision: 'revision-1',
});

const menu = () => document.body.querySelector<HTMLElement>('.chat-list-actions-menu');
const menuItem = (label: string) =>
  Array.from(menu()?.querySelectorAll<HTMLButtonElement>('.menu-item') ?? []).find((item) =>
    item.textContent?.includes(label)
  );

describe('chat list actions menu', () => {
  let wrapper: VueWrapper;
  let queryClient: QueryClient;

  async function mountList() {
    const Host = defineComponent({
      setup() {
        provideStackLayer({ active: ref(true), presented: ref(true), depth: ref(0), setReady: vi.fn() });
        return () => h(ChatsIndexView);
      },
    });
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [
        { path: '/chats', component: { template: '<div />' } },
        { path: '/chats/:id', component: { template: '<div />' } },
      ],
    });
    await router.push('/chats');
    queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    wrapper = mount(Host, {
      attachTo: document.body,
      global: {
        plugins: [router, [VueQueryPlugin, { queryClient }]],
        stubs: {
          BotSelectorModal: true,
          ChatBotFiltersPanel: true,
          ContinuationNav: true,
          InitialRoutePlaceholder: true,
          StackToolbarTeleport: { template: '<div><slot /></div>' },
          SvgIcon: true,
        },
      },
    });
    await flushPromises();
  }

  const rows = () => wrapper.findAll('.chat-list-row');
  const rowTitles = () => wrapper.findAll('.chat-result-name').map((title) => title.text());

  beforeEach(() => {
    vi.stubGlobal('matchMedia', vi.fn((media: string) => ({
      matches: false, media, addEventListener: vi.fn(), removeEventListener: vi.fn(),
    })));
    vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
    apiMocks.get.mockReset().mockImplementation(async (path: string) =>
      path.startsWith('/api/bff/chat-list?') ? listPayload() : undefined
    );
    apiMocks.jsonApiList.mockReset().mockResolvedValue({ data: [] });
    apiMocks.jsonApiUpdate.mockReset().mockResolvedValue({ data: { id: '1' } });
    apiMocks.jsonApiDelete.mockReset().mockResolvedValue(undefined);
  });

  afterEach(() => {
    wrapper?.unmount();
    queryClient?.clear();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('offers actions only for chats the user can edit', async () => {
    await mountList();

    expect(rows()[0].find('.chat-list-row__actions-button').exists()).toBe(true);
    expect(rows()[1].find('.chat-list-row__actions-button').exists()).toBe(false);

    const sharedEvent = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 40, clientY: 50 });
    rows()[1].element.dispatchEvent(sharedEvent);
    await flushPromises();
    expect(sharedEvent.defaultPrevented).toBe(false);
    expect(menu()).toBeNull();

    const ownEvent = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 40, clientY: 50 });
    rows()[0].element.dispatchEvent(ownEvent);
    await flushPromises();
    expect(ownEvent.defaultPrevented).toBe(true);
    expect(menuItem('Edit note')).toBeTruthy();
    expect(menuItem('Delete')).toBeTruthy();
  });

  it('toggles the menu from the row button and closes it on Escape', async () => {
    await mountList();
    const button = rows()[0].get('.chat-list-row__actions-button');

    await button.trigger('click');
    expect(menu()).not.toBeNull();
    expect(button.attributes('aria-expanded')).toBe('true');

    await button.trigger('click');
    expect(menu()).toBeNull();

    await button.trigger('click');
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    await flushPromises();
    expect(menu()).toBeNull();
  });

  it('edits the chat note from the menu', async () => {
    await mountList();
    await rows()[0].get('.chat-list-row__actions-button').trigger('click');
    menuItem('Edit note')!.click();
    await flushPromises();

    expect(menu()).toBeNull();
    const input = document.body.querySelector<HTMLInputElement>('.modal input[type="text"]')!;
    expect(input.value).toBe('Own chat');

    input.value = '  Renamed chat  ';
    input.dispatchEvent(new Event('input'));
    const saveButton = Array.from(document.body.querySelectorAll<HTMLButtonElement>('.modal button')).find(
      (item) => item.textContent?.trim() === 'Save'
    )!;
    saveButton.click();
    await flushPromises();

    expect(apiMocks.jsonApiUpdate).toHaveBeenCalledWith('/api/ash/chats', 'chats', 1, { note: 'Renamed chat' });
    expect(document.body.querySelector('.modal')).toBeNull();
    expect(rowTitles()[0]).toContain('Renamed chat');
  });

  it('deletes the chat after confirmation', async () => {
    await mountList();
    const confirm = vi.spyOn(window, 'confirm').mockReturnValueOnce(false).mockReturnValueOnce(true);

    await rows()[0].get('.chat-list-row__actions-button').trigger('click');
    menuItem('Delete')!.click();
    await flushPromises();
    expect(apiMocks.jsonApiDelete).not.toHaveBeenCalled();
    expect(menu()).toBeNull();

    await rows()[0].get('.chat-list-row__actions-button').trigger('click');
    menuItem('Delete')!.click();
    await flushPromises();

    expect(confirm).toHaveBeenCalledTimes(2);
    expect(apiMocks.jsonApiDelete).toHaveBeenCalledWith('/api/ash/chats', 1);
    expect(rowTitles()).toHaveLength(1);
    expect(rowTitles()[0]).toContain('Shared chat');
  });
});
