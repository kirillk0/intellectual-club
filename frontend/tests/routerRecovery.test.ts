const routerMocks = vi.hoisted(() => {
  const handlers = {
    beforeEach: null as null | ((to: any, from: any) => unknown),
    afterEach: null as null | ((to: any, from: any, failure?: unknown) => unknown),
    onError: null as null | ((error: unknown, to: any, from?: any) => unknown),
    serviceWorkerMessage: null as null | ((event: MessageEvent) => unknown),
  };
  const history = { state: {} };
  const router = {
    beforeEach: vi.fn((handler) => {
      handlers.beforeEach = handler;
    }),
    afterEach: vi.fn((handler) => {
      handlers.afterEach = handler;
    }),
    onError: vi.fn((handler) => {
      handlers.onError = handler;
    }),
    replace: vi.fn(),
    options: { history },
    currentRoute: { value: { fullPath: '/chats' } },
  };

  return {
    handlers,
    history,
    router,
    beginLoadTask: vi.fn(),
    navigateDocumentToRoute: vi.fn(),
    taskHandles: [] as Array<{
      update: ReturnType<typeof vi.fn>;
      finish: ReturnType<typeof vi.fn>;
    }>,
  };
});

vi.mock('vue-router', () => ({
  createRouter: vi.fn(() => routerMocks.router),
  createWebHistory: vi.fn(() => routerMocks.history),
}));
vi.mock('@/features/app/loadCoordinator', () => ({
  beginLoadTask: routerMocks.beginLoadTask,
  setBootstrapLoadStage: vi.fn(),
  startupLoadStartedAt: vi.fn(() => 1_000),
}));
vi.mock('@/features/app/routeRecoveryNavigation', () => ({
  navigateDocumentToRoute: routerMocks.navigateDocumentToRoute,
}));
vi.mock('@/features/auth/session', () => ({
  ensureAuthInitialized: vi.fn(),
  useSessionAuth: () => ({
    currentUser: { value: { id: 1, is_admin: true } },
    isAuthenticated: { value: true },
  }),
}));
vi.mock('@/features/pwa/lastRoute', () => ({
  rememberPwaRoute: vi.fn(),
  restorePwaRouteOnLaunch: vi.fn(() => null),
}));
vi.mock('@/features/stack/navigationStack', () => ({
  useNavigationStack: () => ({
    active: { value: false },
    top: { value: null },
    commitPendingPush: vi.fn(() => null),
    pop: vi.fn(),
    reset: vi.fn(),
  }),
}));

const route = (fullPath: string, matched: unknown[] = [{}]) => ({
  fullPath,
  name: 'test-route',
  meta: { title: 'Test route' },
  matched,
});

const successfulHealth = () =>
  Promise.resolve({ ok: true } as Response);

describe('route chunk recovery', () => {
  const fetchMock = vi.fn();

  beforeEach(async () => {
    vi.resetModules();
    vi.useFakeTimers();
    fetchMock.mockReset();
    vi.stubGlobal('fetch', fetchMock);
    routerMocks.router.replace.mockReset();
    routerMocks.beginLoadTask.mockReset();
    routerMocks.navigateDocumentToRoute.mockReset();
    routerMocks.taskHandles.length = 0;
    routerMocks.handlers.beforeEach = null;
    routerMocks.handlers.afterEach = null;
    routerMocks.handlers.onError = null;
    routerMocks.handlers.serviceWorkerMessage = null;
    routerMocks.history.state = {};
    window.sessionStorage.clear();
    window.history.replaceState({}, '', '/chats');
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true);
    vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible');
    Object.defineProperty(navigator, 'serviceWorker', {
      configurable: true,
      value: {
        addEventListener: vi.fn(
          (type: string, handler: (event: MessageEvent) => unknown) => {
            if (type === 'message') routerMocks.handlers.serviceWorkerMessage = handler;
          }
        ),
      },
    });

    routerMocks.beginLoadTask.mockImplementation(() => {
      const handle = { update: vi.fn(), finish: vi.fn() };
      routerMocks.taskHandles.push(handle);
      return handle;
    });

    await import('@/router');
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('does not let onError inside a retry replace the 10 second backoff', async () => {
    const target = route('/bookmarks');
    const from = route('/chats');
    window.sessionStorage.setItem(
      'intellectual-club:route-reload:test:/bookmarks',
      '1'
    );
    fetchMock.mockImplementation(successfulHealth);
    routerMocks.router.replace.mockImplementation(async () => {
      routerMocks.handlers.onError?.(new TypeError('chunk failed'), target);
      throw new TypeError('chunk failed');
    });

    routerMocks.handlers.beforeEach?.(target, from);
    routerMocks.handlers.onError?.(new TypeError('chunk failed'), target);

    await vi.advanceTimersByTimeAsync(500);
    expect(routerMocks.router.replace).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(9_999);
    expect(routerMocks.router.replace).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(routerMocks.router.replace).toHaveBeenCalledTimes(2);

    const attempts = routerMocks.taskHandles[0].update.mock.calls
      .map(([patch]) => patch.attempt)
      .filter((attempt) => typeof attempt === 'number');
    expect(attempts).toContain(1);
    expect(attempts).toContain(2);
    expect(attempts).toContain(3);
    expect(attempts).not.toContain(4);
  });

  it('retries a failed mid-session deep link without replacing the document', async () => {
    const target = route('/bookmarks?filter=mine#saved');
    const from = route('/chats');
    fetchMock.mockImplementation(successfulHealth);
    routerMocks.router.replace.mockResolvedValue(undefined);

    routerMocks.handlers.beforeEach?.(target, from);
    routerMocks.handlers.onError?.(new TypeError('chunk failed'), target);
    await vi.advanceTimersByTimeAsync(500);

    expect(routerMocks.router.replace).toHaveBeenCalledWith(
      '/bookmarks?filter=mine#saved'
    );
    expect(routerMocks.navigateDocumentToRoute).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(10_000);
    expect(routerMocks.router.replace).toHaveBeenCalledTimes(1);
  });

  it('falls back to one guarded document navigation when a mid-session chunk stays failed', async () => {
    const target = route('/settings');
    const from = route('/bookmarks');
    fetchMock.mockImplementation(successfulHealth);
    routerMocks.router.replace.mockImplementation(async () => {
      routerMocks.handlers.onError?.(new TypeError('chunk failed'), target);
      throw new TypeError('chunk failed');
    });

    routerMocks.handlers.beforeEach?.(target, from);
    routerMocks.handlers.onError?.(new TypeError('chunk failed'), target);
    await vi.advanceTimersByTimeAsync(500);

    expect(routerMocks.router.replace).toHaveBeenCalledWith('/settings');
    expect(routerMocks.navigateDocumentToRoute).toHaveBeenCalledTimes(1);
    expect(routerMocks.navigateDocumentToRoute).toHaveBeenCalledWith('/settings');

    await vi.advanceTimersByTimeAsync(10_000);
    expect(routerMocks.navigateDocumentToRoute).toHaveBeenCalledTimes(1);
  });

  it('recovers a navigation whose lazy route import never settles', async () => {
    const target = route('/catalogs/bots');
    fetchMock.mockImplementation(successfulHealth);

    routerMocks.handlers.beforeEach?.(target, route('/boot', []));
    await vi.advanceTimersByTimeAsync(14_999);
    expect(routerMocks.navigateDocumentToRoute).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(fetchMock).toHaveBeenCalledWith(
      '/health',
      expect.objectContaining({ cache: 'no-store' })
    );
    expect(routerMocks.navigateDocumentToRoute).toHaveBeenCalledWith(
      '/catalogs/bots'
    );
  });

  it('cancels an in-flight recovery when the user starts another navigation', async () => {
    let resolveHealth!: (response: Response) => void;
    fetchMock.mockReturnValue(
      new Promise<Response>((resolve) => {
        resolveHealth = resolve;
      })
    );
    const failed = route('/bookmarks');
    const next = route('/settings');

    routerMocks.handlers.beforeEach?.(failed, route('/chats'));
    routerMocks.handlers.onError?.(new TypeError('chunk failed'), failed);
    await vi.advanceTimersByTimeAsync(500);
    expect(fetchMock).toHaveBeenCalledTimes(1);

    routerMocks.handlers.beforeEach?.(next, route('/chats'));
    resolveHealth({ ok: true } as Response);
    await Promise.resolve();
    await Promise.resolve();

    expect(routerMocks.router.replace).not.toHaveBeenCalled();
    expect(routerMocks.navigateDocumentToRoute).not.toHaveBeenCalled();
  });

  it('ignores a late cancellation callback from the previous navigation', async () => {
    const first = route('/bookmarks');
    const second = route('/settings');
    fetchMock.mockImplementation(successfulHealth);

    routerMocks.handlers.beforeEach?.(first, route('/chats'));
    const firstTask = routerMocks.taskHandles[0];
    routerMocks.handlers.beforeEach?.(second, route('/chats'));
    const secondTask = routerMocks.taskHandles[1];
    routerMocks.handlers.afterEach?.(first, route('/chats'), {
      type: 'cancelled',
    });

    expect(firstTask.finish).toHaveBeenCalled();
    expect(secondTask.finish).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(15_000);
    await vi.advanceTimersByTimeAsync(1);
    expect(routerMocks.router.replace).toHaveBeenCalledWith('/settings');
    expect(routerMocks.navigateDocumentToRoute).not.toHaveBeenCalled();
  });

  it('uses only runtime service-worker retries for the active route', async () => {
    const target = route('/catalogs/tools');
    fetchMock.mockImplementation(successfulHealth);
    routerMocks.handlers.beforeEach?.(target, route('/chats'));
    const task = routerMocks.taskHandles[0];

    routerMocks.handlers.serviceWorkerMessage?.(
      new MessageEvent('message', {
        data: {
          type: 'ASSET_RETRY',
          context: 'precache',
          url: '/assets/js/chunks/ToolView.js',
          attempt: 7,
        },
      })
    );
    expect(task.update).not.toHaveBeenCalledWith(
      expect.objectContaining({ attempt: 7 })
    );

    routerMocks.handlers.serviceWorkerMessage?.(
      new MessageEvent('message', {
        data: {
          type: 'ASSET_RETRY',
          context: 'runtime',
          url: '/assets/js/chunks/ToolView.js',
          attempt: 3,
        },
      })
    );
    expect(task.update).toHaveBeenCalledWith(
      expect.objectContaining({ attempt: 3, retrying: true })
    );

    routerMocks.handlers.serviceWorkerMessage?.(
      new MessageEvent('message', {
        data: {
          type: 'VERSION_MISMATCH',
          context: 'runtime',
          url: '/assets/js/chunks/ToolView.js',
        },
      })
    );
    await vi.advanceTimersByTimeAsync(0);
    expect(routerMocks.router.replace).toHaveBeenCalledWith('/catalogs/tools');
    expect(routerMocks.navigateDocumentToRoute).not.toHaveBeenCalled();
  });
});
