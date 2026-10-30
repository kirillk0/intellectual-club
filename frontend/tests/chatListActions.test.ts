import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
import { defineComponent, h, ref } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  post: vi.fn(),
  jsonApiList: vi.fn(),
  jsonApiUpdate: vi.fn(),
  jsonApiDelete: vi.fn(),
}));

vi.mock('@/api/client', () => ({ api: { get: apiMocks.get, post: apiMocks.post } }));
vi.mock('@/api/jsonApi', async () => ({
  ...(await vi.importActual<typeof import('@/api/jsonApi')>('@/api/jsonApi')),
  jsonApiList: apiMocks.jsonApiList,
  jsonApiUpdate: apiMocks.jsonApiUpdate,
  jsonApiDelete: apiMocks.jsonApiDelete,
}));

import ChatsIndexView from '@/views/ChatsIndexView.vue';
import ChatSnoozeModal from '@/components/chat/ChatSnoozeModal.vue';
import { chatReadStateInput, updateChatReadState } from '@/features/chat/chatReadState';
import type { ChatReadState } from '@/types/api';
import { provideStackLayer } from '@/features/stack/useStackLayer';

const readState = (patch: Partial<ChatReadState> = {}): ChatReadState => ({
  activity_revision: 8, read_revision: 8, manual_unread: false, snoozed_until: null,
  state_version: 2, has_unread: false, is_unread: false, is_snoozed: false, ...patch,
});

const chatRow = (id: number, note: string, canEdit: boolean) => ({
  id,
  note,
  bot_id: null,
  bot_name: '',
  created_at: '2026-09-06T00:00:00Z',
  last_activity_at: '2026-09-06T00:00:00Z',
  message_count: 0,
  can_edit: canEdit,
  read_state: readState(),
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
    apiMocks.post.mockReset();
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

  it('offers read-state actions for shared chats but restricts edit and delete', async () => {
    await mountList();

    expect(rows()[0].find('.chat-list-row__actions-button').exists()).toBe(true);
    expect(rows()[1].find('.chat-list-row__actions-button').exists()).toBe(true);

    const sharedEvent = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 40, clientY: 50 });
    rows()[1].element.dispatchEvent(sharedEvent);
    await flushPromises();
    expect(sharedEvent.defaultPrevented).toBe(true);
    expect(menuItem('Mark as unread')).toBeTruthy();
    expect(menuItem('Snooze')).toBeTruthy();
    expect(menuItem('Edit note')).toBeUndefined();
    expect(menuItem('Delete')).toBeUndefined();

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
    apiMocks.jsonApiDelete.mockImplementation(async () => {
      apiMocks.get.mockImplementation(async (path: string) => path.startsWith('/api/bff/chat-list?')
        ? { ...listPayload(), chats: [chatRow(2, 'Shared chat', false)] } : undefined);
    });
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

  it('moves a shared chat to unread once and sends the expected version', async () => {
    await mountList();
    apiMocks.post.mockImplementation(async () => {
      const moved = { ...chatRow(2, 'Shared chat', false), read_state: readState({ manual_unread: true, has_unread: true, is_unread: true, state_version: 3 }) };
      apiMocks.get.mockImplementation(async (path: string) => path.startsWith('/api/bff/chat-list?')
        ? { ...listPayload(), chats: new URL(path, 'http://localhost').searchParams.get('section') === 'unread' ? [moved] : [chatRow(1, 'Own chat', true)] } : undefined);
      return { read_state: moved.read_state };
    });
    await rows()[1].get('.chat-list-row__actions-button').trigger('click');
    menuItem('Mark as unread')!.click();
    await flushPromises();
    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-state/2/read-state', {
      action: 'unread', expected_state_version: 2,
    }, { retry: false, showErrorBanner: false });
    expect(wrapper.get('[data-section="unread"]').findAll('.chat-list-row')).toHaveLength(1);
    expect(wrapper.get('[data-section="other"]').text()).not.toContain('Shared chat');
    expect(rowTitles().filter((title) => title.includes('Shared chat'))).toHaveLength(1);
    expect(wrapper.findAll('.chat-unread-dot')).toHaveLength(1);
  });

  it('refreshes on a stale state conflict without retrying the write', async () => {
    await mountList();
    const before = apiMocks.get.mock.calls.length;
    apiMocks.post.mockRejectedValue({ status: 409 });
    await rows()[0].get('.chat-list-row__actions-button').trigger('click');
    menuItem('Mark as unread')!.click();
    await flushPromises();
    expect(apiMocks.post).toHaveBeenCalledTimes(1);
    expect(apiMocks.get.mock.calls.length - before).toBe(3);
    expect(wrapper.text()).toContain('Chat state changed. Please try again.');
  });

  it('marks a snoozed chat explicitly read using its observed activity revision', async () => {
    const state = readState({ manual_unread: true, has_unread: true, is_snoozed: true, snoozed_until: '2099-01-01T09:00:00Z' });
    apiMocks.get.mockResolvedValue({ ...listPayload(), chats: [{ ...chatRow(1, 'Snoozed', false), read_state: state }] });
    apiMocks.post.mockResolvedValue({ read_state: readState({ state_version: 3 }) });
    await mountList();
    expect(wrapper.get('.chat-snoozed').attributes('title')).toContain('Snoozed until');
    await rows()[0].get('.chat-list-row__actions-button').trigger('click');
    expect(menuItem('Unsnooze')).toBeTruthy();
    menuItem('Mark as read')!.click();
    await flushPromises();
    expect(apiMocks.post.mock.calls[0][1]).toEqual({ action: 'read', expected_state_version: 2, observed_revision: 8, explicit: true });
  });

  it('keeps automatic reads explicit=false and unwraps the shared API result', async () => {
    const next = readState({ state_version: 3 });
    apiMocks.post.mockResolvedValue({ read_state: next });
    const input = chatReadStateInput(readState(), 'read', { explicit: false });
    expect(input).toEqual({ action: 'read', expected_state_version: 2, observed_revision: 8, explicit: false });
    expect(await updateChatReadState(1, input)).toEqual(next);
  });

  it('validates custom snooze time and emits a UTC ISO without closing itself', async () => {
    const modal = mount(ChatSnoozeModal, { props: { open: true }, global: { stubs: { ModalWindow: { template: '<div><slot /></div>' } } } });
    const input = modal.get('input[type="datetime-local"]');
    const confirm = () => modal.get('button.primary');
    await input.setValue('2000-01-01T09:00');
    await confirm().trigger('click');
    expect(modal.emitted('confirm')).toBeUndefined();
    expect(modal.text()).toContain('Choose a future date and time.');
    await input.setValue('2099-07-01T10:30');
    await confirm().trigger('click');
    expect(modal.emitted('confirm')?.[0]).toEqual([new Date('2099-07-01T10:30').toISOString()]);
    expect(modal.emitted('update:open')).toBeUndefined();
    await modal.setProps({ saving: true });
    expect(confirm().attributes('disabled')).toBeDefined();
    await modal.setProps({ saving: false });
    await modal.findAll('button').find((button) => button.text() === 'Tomorrow morning')!.trigger('click');
    const tomorrow = new Date(); tomorrow.setDate(tomorrow.getDate() + 1); tomorrow.setHours(9, 0, 0, 0);
    await confirm().trigger('click');
    expect(modal.emitted('confirm')?.[1]).toEqual([tomorrow.toISOString()]);
    await modal.findAll('button').find((button) => button.text() === 'Cancel')!.trigger('click');
    expect(modal.emitted('update:open')?.[0]).toEqual([false]);
    modal.unmount();
  });


  it('snoozes from the list modal and unsnoozes without marking the chat read', async () => {
    await mountList();
    const snoozed = readState({ manual_unread: true, has_unread: true, is_snoozed: true, snoozed_until: '2099-07-01T10:30:00Z', state_version: 3 });
    apiMocks.post.mockImplementationOnce(async () => {
      apiMocks.get.mockResolvedValue({ chats: [{ ...chatRow(1, 'Own chat', true), read_state: snoozed }] });
      return { read_state: snoozed };
    });
    await rows()[0].get('.chat-list-row__actions-button').trigger('click');
    menuItem('Snooze')!.click();
    await flushPromises();
    const input = document.body.querySelector<HTMLInputElement>('input[type="datetime-local"]')!;
    input.value = '2099-07-01T10:30'; input.dispatchEvent(new Event('input'));
    document.body.querySelector<HTMLButtonElement>('.modal button.primary')!.click();
    await flushPromises();
    expect(apiMocks.post.mock.calls[0][1]).toEqual({ action: 'snooze', expected_state_version: 2, snoozed_until: new Date('2099-07-01T10:30').toISOString() });
    expect(document.body.querySelector('.modal')).toBeNull();
    expect(wrapper.get('[data-section="other"]').text()).toContain('Own chat');
    const unread = readState({ manual_unread: true, has_unread: true, is_unread: true, state_version: 4 });
    apiMocks.post.mockImplementationOnce(async () => {
      apiMocks.get.mockResolvedValue({ chats: [{ ...chatRow(1, 'Own chat', true), read_state: unread }] });
      return { read_state: unread };
    });
    await rows()[0].get('.chat-list-row__actions-button').trigger('click');
    menuItem('Unsnooze')!.click();
    await flushPromises();
    expect(apiMocks.post.mock.calls[1][1]).toEqual({ action: 'unsnooze', expected_state_version: 3 });
    expect(wrapper.get('[data-section="unread"]').text()).toContain('Own chat');
    expect(wrapper.find('.chat-snoozed').exists()).toBe(false);
  });

  it('renders failed and canceled generation independently from read state and never infers completion', async () => {
    apiMocks.get.mockResolvedValue({ chats: [
      { ...chatRow(1, 'Failed unread', true), last_message_status: 'error', read_state: readState({ has_unread: true, is_unread: true }) },
      { ...chatRow(2, 'Canceled read', false), last_message_status: 'canceled' },
      { ...chatRow(3, 'Completed read', false), last_message_status: 'done' },
    ] });
    await mountList();
    const unread = wrapper.get('[data-section="unread"]');
    expect(unread.find('.chat-generation-state--error').exists()).toBe(true);
    expect(unread.find('.chat-unread-dot').exists()).toBe(true);
    const other = wrapper.get('[data-section="other"]');
    expect(other.find('.chat-generation-state--canceled').exists()).toBe(true);
    expect(other.find('.chat-unread-dot').exists()).toBe(false);
    expect(wrapper.find('.chat-generation-state--done').exists()).toBe(false);
  });

});
