const bootstrapMocks = vi.hoisted(() => {
  const app = {
    use: vi.fn(),
    mount: vi.fn(),
  };
  app.use.mockReturnValue(app);

  return {
    app,
    createApp: vi.fn(() => app),
    installDomTranslations: vi.fn(),
    requestRecoveryNow: vi.fn(),
    setBootstrapLoadStage: vi.fn(),
    setupPwa: vi.fn(),
    setupInitialQueryLoadBridge: vi.fn(),
    setupScrollableTabs: vi.fn(),
    router: {
      isReady: vi.fn(() => new Promise<void>(() => undefined)),
    },
  };
});

vi.mock('vue', () => ({
  createApp: bootstrapMocks.createApp,
}));
vi.mock('@tanstack/vue-query', () => ({
  VueQueryPlugin: Symbol('VueQueryPlugin'),
}));
vi.mock('@/App.vue', () => ({ default: {} }));
vi.mock('@/i18n', () => ({ i18n: Symbol('i18n') }));
vi.mock('@/i18n/dom', () => ({
  installDomTranslations: bootstrapMocks.installDomTranslations,
}));
vi.mock('@/features/app/loadCoordinator', () => ({
  setBootstrapLoadStage: bootstrapMocks.setBootstrapLoadStage,
}));
vi.mock('@/features/app/recoveryHeartbeat', () => ({
  requestRecoveryNow: bootstrapMocks.requestRecoveryNow,
}));
vi.mock('@/pwa', () => ({ setupPwa: bootstrapMocks.setupPwa }));
vi.mock('@/router', () => ({ router: bootstrapMocks.router }));
vi.mock('@/features/serverState/queryClient', () => ({
  serverStateQueryClient: Symbol('queryClient'),
}));
vi.mock('@/features/serverState/queryLoadBridge', () => ({
  setupInitialQueryLoadBridge: bootstrapMocks.setupInitialQueryLoadBridge,
}));
vi.mock('@/utils/scrollableTabs', () => ({
  setupScrollableTabs: bootstrapMocks.setupScrollableTabs,
}));

describe('SPA bootstrap', () => {
  beforeEach(() => {
    vi.resetModules();
    Object.values(bootstrapMocks).forEach((value) => {
      if (typeof value === 'function' && 'mockClear' in value) value.mockClear();
    });
    bootstrapMocks.app.use.mockClear();
    bootstrapMocks.app.mount.mockClear();
    bootstrapMocks.app.use.mockReturnValue(bootstrapMocks.app);
    bootstrapMocks.router.isReady.mockClear();
    document.body.innerHTML = '<div id="spa-root"></div>';
  });

  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('mounts and initializes browser integrations without waiting for router readiness', async () => {
    const root = document.getElementById('spa-root');
    await import('@/main');

    expect(bootstrapMocks.setupPwa).toHaveBeenCalledTimes(1);
    expect(bootstrapMocks.setBootstrapLoadStage).toHaveBeenCalledWith('route');
    expect(bootstrapMocks.setupInitialQueryLoadBridge).toHaveBeenCalledTimes(1);
    expect(bootstrapMocks.requestRecoveryNow).toHaveBeenCalledTimes(1);
    expect(bootstrapMocks.app.mount).toHaveBeenCalledWith(root);
    expect(bootstrapMocks.installDomTranslations).toHaveBeenCalledWith(document.body);
    expect(bootstrapMocks.setupScrollableTabs).toHaveBeenCalledWith(root);
    expect(bootstrapMocks.router.isReady).not.toHaveBeenCalled();
  });
});
