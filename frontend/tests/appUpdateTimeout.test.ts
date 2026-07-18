const serviceWorkerMocks = vi.hoisted(() => ({
  getRegistration: vi.fn(),
}));

vi.mock('@/features/pwa/serviceWorker', () => ({
  getServiceWorkerRegistration: serviceWorkerMocks.getRegistration,
}));

const currentVersion = {
  commit_timestamp: '',
  commit_sha: '',
  dirty: false,
  label: 'test',
};

const nextVersion = {
  commit_timestamp: '2026-07-18T12:00:00Z',
  commit_sha: 'next',
  dirty: false,
  label: 'next',
};

const versionResponse = (version: typeof currentVersion) => ({
  ok: true,
  json: async () => version,
});

const registration = (waiting: ServiceWorker | null = null) => ({
  update: vi.fn().mockResolvedValue(undefined),
  waiting,
});

const statefulWorker = (initialState: ServiceWorkerState) => {
  let state = initialState;
  const worker = new EventTarget() as ServiceWorker;
  const postMessage = vi.fn();

  Object.defineProperties(worker, {
    state: { configurable: true, get: () => state },
    postMessage: { configurable: true, value: postMessage },
  });

  return {
    worker,
    postMessage,
    setState(nextState: ServiceWorkerState) {
      state = nextState;
      worker.dispatchEvent(new Event('statechange'));
    },
  };
};

const stubWindowReload = (onReload?: () => void) => {
  const actualWindow = window;
  const reloadPage = vi.fn(() => onReload?.());

  vi.stubGlobal(
    'window',
    new Proxy(actualWindow, {
      get(target, property, receiver) {
        if (property === 'location') {
          return {
            origin: target.location.origin,
            reload: reloadPage,
          };
        }
        return Reflect.get(target, property, receiver);
      },
    })
  );

  return reloadPage;
};

describe('app update monitor timeouts', () => {
  beforeEach(() => {
    vi.resetModules();
    vi.useFakeTimers();
    serviceWorkerMocks.getRegistration.mockReset();
    Object.defineProperty(navigator, 'serviceWorker', {
      configurable: true,
      value: {},
    });
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('releases the single-flight check when registration.update never resolves', async () => {
    serviceWorkerMocks.getRegistration.mockResolvedValue({
      update: () => new Promise(() => undefined),
      waiting: null,
    });
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(versionResponse(currentVersion))
    );

    const { checkNow, useAppUpdateMonitor } = await import('@/features/pwa/appUpdate');
    const firstCheck = checkNow();
    expect(useAppUpdateMonitor().checking.value).toBe(true);

    await vi.advanceTimersByTimeAsync(10_000);
    await firstCheck;

    expect(useAppUpdateMonitor().checking.value).toBe(false);
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(checkNow()).not.toBe(firstCheck);
  });

  it('does not announce an update from a waiting worker without a confirmed remote version', async () => {
    const waiting = { postMessage: vi.fn() } as unknown as ServiceWorker;
    serviceWorkerMocks.getRegistration.mockResolvedValue(registration(waiting));
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('offline')));

    const { checkNow, useAppUpdateMonitor } = await import('@/features/pwa/appUpdate');
    await checkNow();

    expect(useAppUpdateMonitor().available.value).toBe(false);
    expect(useAppUpdateMonitor().latestVersion.value).toBeNull();
  });

  it('does not announce an update from malformed version metadata', async () => {
    const waiting = { postMessage: vi.fn() } as unknown as ServiceWorker;
    serviceWorkerMocks.getRegistration.mockResolvedValue(registration(waiting));
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: true, json: async () => ({}) })
    );

    const { checkNow, useAppUpdateMonitor } = await import('@/features/pwa/appUpdate');
    await checkNow();

    expect(useAppUpdateMonitor().available.value).toBe(false);
    expect(useAppUpdateMonitor().latestVersion.value).toBeNull();
  });

  it('announces a confirmed remote version mismatch', async () => {
    serviceWorkerMocks.getRegistration.mockResolvedValue(registration());
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(versionResponse(nextVersion)));

    const { checkNow, useAppUpdateMonitor } = await import('@/features/pwa/appUpdate');
    await checkNow();

    expect(useAppUpdateMonitor().available.value).toBe(true);
    expect(useAppUpdateMonitor().latestVersion.value).toEqual(nextVersion);
  });

  it('preserves a confirmed update across an inconclusive check', async () => {
    serviceWorkerMocks.getRegistration
      .mockResolvedValueOnce(registration())
      .mockRejectedValueOnce(new TypeError('registration unavailable'));
    vi.stubGlobal(
      'fetch',
      vi.fn()
        .mockResolvedValueOnce(versionResponse(nextVersion))
        .mockRejectedValueOnce(new TypeError('offline'))
    );

    const { checkNow, useAppUpdateMonitor } = await import('@/features/pwa/appUpdate');
    await checkNow();

    expect(useAppUpdateMonitor().available.value).toBe(true);
    expect(useAppUpdateMonitor().latestVersion.value).toEqual(nextVersion);

    await checkNow();

    expect(useAppUpdateMonitor().available.value).toBe(true);
    expect(useAppUpdateMonitor().latestVersion.value).toEqual(nextVersion);
  });

  it('clears a confirmed update when the remote version is current despite a waiting worker', async () => {
    const waiting = { postMessage: vi.fn() } as unknown as ServiceWorker;
    serviceWorkerMocks.getRegistration
      .mockResolvedValueOnce(registration())
      .mockResolvedValueOnce(registration(waiting));
    vi.stubGlobal(
      'fetch',
      vi.fn()
        .mockResolvedValueOnce(versionResponse(nextVersion))
        .mockResolvedValueOnce(versionResponse(currentVersion))
    );

    const { checkNow, useAppUpdateMonitor } = await import('@/features/pwa/appUpdate');
    await checkNow();
    expect(useAppUpdateMonitor().available.value).toBe(true);

    await checkNow();

    expect(useAppUpdateMonitor().available.value).toBe(false);
    expect(useAppUpdateMonitor().latestVersion.value).toBeNull();
  });

  it('activates an existing waiting worker without waiting for a stalled update check', async () => {
    const reloadPage = stubWindowReload();

    const serviceWorker = new EventTarget();
    Object.defineProperty(navigator, 'serviceWorker', {
      configurable: true,
      value: serviceWorker,
    });

    const waiting = statefulWorker('installed');
    const update = vi.fn(() => new Promise<void>(() => undefined));
    serviceWorkerMocks.getRegistration.mockResolvedValue({ update, waiting: waiting.worker });

    const { reload, useAppUpdateMonitor } = await import('@/features/pwa/appUpdate');
    let completed = false;
    const firstReload = reload();
    const secondReload = reload();
    const reloadPromise = firstReload.then(() => {
      completed = true;
    });

    expect(secondReload).toBe(firstReload);
    expect(useAppUpdateMonitor().reloading.value).toBe(true);
    await Promise.resolve();
    await Promise.resolve();

    expect(waiting.postMessage).toHaveBeenCalledWith({ type: 'ACTIVATE_UPDATE' });
    expect(update).not.toHaveBeenCalled();
    expect(reloadPage).not.toHaveBeenCalled();
    expect(completed).toBe(false);

    waiting.setState('activated');
    await Promise.resolve();
    await Promise.resolve();

    expect(reloadPage).toHaveBeenCalledTimes(1);
    expect(completed).toBe(false);
    expect(useAppUpdateMonitor().reloading.value).toBe(true);
  });

  it('activates the newest installing worker when an older update is waiting', async () => {
    const reloadPage = stubWindowReload();

    const serviceWorker = new EventTarget();
    Object.defineProperty(navigator, 'serviceWorker', {
      configurable: true,
      value: serviceWorker,
    });

    const waiting = statefulWorker('installed');
    const installing = statefulWorker('installing');
    serviceWorkerMocks.getRegistration.mockResolvedValue({
      update: vi.fn(),
      waiting: waiting.worker,
      installing: installing.worker,
    });

    const { reload } = await import('@/features/pwa/appUpdate');
    void reload();
    await Promise.resolve();
    await Promise.resolve();

    expect(installing.postMessage).toHaveBeenCalledWith({ type: 'ACTIVATE_UPDATE' });
    expect(waiting.postMessage).not.toHaveBeenCalled();

    serviceWorker.dispatchEvent(new Event('controllerchange'));
    await Promise.resolve();
    await Promise.resolve();

    expect(reloadPage).not.toHaveBeenCalled();

    installing.setState('activated');
    await Promise.resolve();
    await Promise.resolve();

    expect(reloadPage).toHaveBeenCalledTimes(1);
  });

  it('falls back to a document reload when worker activation fails', async () => {
    const reloadPage = stubWindowReload();
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    const serviceWorker = new EventTarget();
    Object.defineProperty(navigator, 'serviceWorker', {
      configurable: true,
      value: serviceWorker,
    });

    const waiting = statefulWorker('installed');
    serviceWorkerMocks.getRegistration.mockResolvedValue({ waiting: waiting.worker });

    const { reload, useAppUpdateMonitor } = await import('@/features/pwa/appUpdate');
    void reload();
    await Promise.resolve();
    await Promise.resolve();

    waiting.setState('redundant');
    await Promise.resolve();
    await Promise.resolve();

    expect(warn).toHaveBeenCalledWith(
      'Service worker update activation failed.',
      expect.any(Error)
    );
    expect(reloadPage).toHaveBeenCalledTimes(1);
    expect(useAppUpdateMonitor().reloading.value).toBe(true);
  });

  it('restores the update action when a beforeunload prompt cancels the reload', async () => {
    const actualWindow = window;
    const reloadPage = stubWindowReload(() => {
      const event = new Event('beforeunload', { cancelable: true });
      event.preventDefault();
      actualWindow.dispatchEvent(event);
    });
    Reflect.deleteProperty(navigator, 'serviceWorker');

    const { reload, useAppUpdateMonitor } = await import('@/features/pwa/appUpdate');
    const reloadPromise = reload();

    expect(useAppUpdateMonitor().reloading.value).toBe(true);
    expect(reloadPage).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(999);
    expect(useAppUpdateMonitor().reloading.value).toBe(true);

    await vi.advanceTimersByTimeAsync(1);
    await reloadPromise;

    expect(useAppUpdateMonitor().reloading.value).toBe(false);
  });
});
