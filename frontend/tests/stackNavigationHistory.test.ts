import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { defineComponent, h } from 'vue';

vi.mock('@/features/auth/session', () => ({
  ensureAuthInitialized: vi.fn(),
  useSessionAuth: () => ({
    currentUser: { value: { id: 1, is_admin: true } },
    initialized: { value: true },
    isAuthenticated: { value: true },
  }),
}));
vi.mock('@/features/app/loadCoordinator', () => ({
  beginLoadTask: () => ({ update: vi.fn(), finish: vi.fn() }),
  setBootstrapLoadStage: vi.fn(),
  startupLoadStartedAt: () => Date.now(),
}));
vi.mock('@/features/app/recoveryHeartbeat', () => ({
  subscribeRecoveryHeartbeat: vi.fn(() => () => undefined),
}));
vi.mock('@/features/pwa/lastRoute', () => ({
  rememberPwaRoute: vi.fn(),
  restorePwaRouteOnLaunch: vi.fn(() => null),
}));
vi.mock('@/features/serverState/queryClient', () => ({
  invalidateServerStateQueries: vi.fn(),
}));
vi.mock('@/views/ChatsIndexView.vue', async () => ({
  default: (await import('vue')).markRaw({ template: '<div>Chats</div>' }),
}));
vi.mock('@/views/ChatView.vue', async () => ({
  default: (await import('vue')).markRaw({ template: '<div>Chat</div>' }),
}));
vi.mock('@/views/UserSettingsView.vue', async () => ({
  default: (await import('vue')).markRaw({ template: '<div>Settings</div>' }),
}));
vi.mock('@/views/catalogs/BotEditView.vue', async () => ({
  default: (await import('vue')).markRaw({ template: '<div>Bot</div>' }),
}));

import StackRouterView from '@/components/StackRouterView.vue';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import { router } from '@/router';

describe('stack navigation with browser history', () => {
  const stack = useNavigationStack();
  const listPath = '/?search=navigation';
  let wrapper: VueWrapper;
  let navigation: ReturnType<typeof useStackNavigation>;

  const expectRoute = async (path: string) => {
    await vi.waitFor(() => expect(router.currentRoute.value.fullPath).toBe(path));
    await flushPromises();
  };

  beforeEach(async () => {
    stack.reset();
    vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
    await router.replace('/settings');
    const Harness = defineComponent({
      setup() {
        navigation = useStackNavigation();
        return () => h(StackRouterView);
      },
    });
    wrapper = mount(Harness, { global: { plugins: [router] } });
    await router.isReady();
    await router.push(listPath);
    await navigation.open('/chats/1');
    await navigation.push('/chats/2');
    await navigation.push('/chats/3');
    await flushPromises();
  });

  afterEach(() => {
    wrapper.unmount();
    stack.reset();
  });

  afterAll(() => router.options.history.destroy());

  it('closes the whole chat layer and keeps closed chats out of the back path', async () => {
    expect(stack.stack.value).toHaveLength(1);
    expect(wrapper.findAll('.stack-layer')).toHaveLength(2);

    navigation.close();
    await expectRoute(listPath);
    expect(stack.active.value).toBe(false);
    expect(wrapper.findAll('.stack-layer')).toHaveLength(1);

    await navigation.open('/chats/4');
    navigation.close();
    await expectRoute(listPath);
    router.back();
    await expectRoute('/settings');
  });

  it('preserves Back and Forward within one layer and closes from a previous chat', async () => {
    router.back();
    await expectRoute('/chats/2');
    router.forward();
    await expectRoute('/chats/3');
    router.back();
    await expectRoute('/chats/2');
    expect(stack.stack.value).toHaveLength(1);
    expect(wrapper.findAll('.stack-layer')).toHaveLength(2);

    navigation.close();
    await expectRoute(listPath);
    expect(stack.active.value).toBe(false);
  });

  it('closes a nested editor to the current chat and completes its result', async () => {
    const result = navigation.openForResult<number>('/catalogs/bots/1');
    await expectRoute('/catalogs/bots/1');
    await navigation.replace('/catalogs/bots/2');
    expect(stack.stack.value).toHaveLength(2);
    expect(wrapper.findAll('.stack-layer')).toHaveLength(3);
    navigation.setLayerResult(42);

    navigation.close();
    await expectRoute('/chats/3');
    await expect(result).resolves.toEqual({ status: 'completed', value: 42 });
    expect(stack.stack.value).toHaveLength(1);

    navigation.close();
    await expectRoute(listPath);
    expect(stack.active.value).toBe(false);
  });

  it('does not count duplicated or blocked transitions when closing the layer', async () => {
    await navigation.push('/chats/3');
    const removeGuard = router.beforeEach((to) => to.path !== '/chats/4');
    try {
      await navigation.push('/chats/4');
    } finally {
      removeGuard();
    }
    expect(router.currentRoute.value.path).toBe('/chats/3');

    navigation.close();
    await expectRoute(listPath);
  });
});
