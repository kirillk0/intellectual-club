import { mount, type VueWrapper } from '@vue/test-utils';
import { ref } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

const viewModelMocks = vi.hoisted(() => ({
  useChatViewModel: vi.fn(),
}));

const appUpdateMocks = vi.hoisted(() => ({
  reload: vi.fn(),
}));

vi.mock('@/features/chat/useChatViewModel', () => viewModelMocks);
vi.mock('@/features/pwa/appUpdate', () => appUpdateMocks);

import ChatView from '@/views/ChatView.vue';
import { i18n, setPreferredLocale } from '@/i18n';

let activeWrapper: VueWrapper | null = null;
let requestAnimationFrameSpy: ReturnType<typeof vi.spyOn>;

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
    appUpdateMocks.reload.mockReset();
    requestAnimationFrameSpy = vi
      .spyOn(window, 'requestAnimationFrame')
      .mockImplementation((callback) => {
        callback(0);
        return 1;
      });
    viewModelMocks.useChatViewModel.mockReset();
    viewModelMocks.useChatViewModel.mockReturnValue({
      loaded: ref(false),
      chat: ref(null),
      sharedReadonly: ref(false),
      handoffPending: ref(false),
    });
    setPreferredLocale('en');
  });

  afterEach(() => {
    requestAnimationFrameSpy.mockRestore();
    activeWrapper?.unmount();
    activeWrapper = null;
    setPreferredLocale(null);
  });

  it('offers a full page reload while the chat is loading', async () => {
    const wrapper = await mountChatView();

    expect(wrapper.find('.spa-boot').exists()).toBe(true);
    expect(wrapper.get('[role="status"]').text()).toBe('Loading…');
    const reloadButton = wrapper.get('button');
    expect(reloadButton.text()).toBe('Reload');

    await reloadButton.trigger('click');

    expect(reloadButton.attributes('disabled')).toBeDefined();
    expect(reloadButton.attributes('aria-busy')).toBe('true');
    expect(reloadButton.classes()).toContain('spa-boot__reload--pending');
    expect(appUpdateMocks.reload).toHaveBeenCalledTimes(1);
  });

  it('translates the loading state and reload action', async () => {
    setPreferredLocale('ru');
    const wrapper = await mountChatView();

    expect(wrapper.get('[role="status"]').text()).toBe('Загрузка…');
    expect(wrapper.get('button').text()).toBe('Перезагрузить');
  });
});
