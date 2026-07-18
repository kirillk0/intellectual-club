import { mount, type VueWrapper } from '@vue/test-utils';
import { ref } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

const viewModelMocks = vi.hoisted(() => ({
  useChatViewModel: vi.fn(),
}));

vi.mock('@/features/chat/useChatViewModel', () => viewModelMocks);

import ChatView from '@/views/ChatView.vue';
import { i18n, setPreferredLocale } from '@/i18n';

let activeWrapper: VueWrapper | null = null;

async function mountChatView() {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/chats/:id', name: 'chat', component: { template: '<div />' } }],
  });
  await router.push('/chats/1');
  await router.isReady();

  activeWrapper = mount(ChatView, {
    global: {
      plugins: [router, i18n],
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
});
