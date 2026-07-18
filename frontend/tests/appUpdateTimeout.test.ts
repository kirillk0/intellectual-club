const serviceWorkerMocks = vi.hoisted(() => ({
  getRegistration: vi.fn(),
  postMessage: vi.fn(),
}));

vi.mock('@/features/pwa/serviceWorker', () => ({
  getServiceWorkerRegistration: serviceWorkerMocks.getRegistration,
  postServiceWorkerMessage: serviceWorkerMocks.postMessage,
}));

describe('app update monitor timeouts', () => {
  beforeEach(() => {
    vi.resetModules();
    vi.useFakeTimers();
    serviceWorkerMocks.getRegistration.mockReset();
    serviceWorkerMocks.postMessage.mockReset();
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
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          commit_timestamp: '',
          commit_sha: '',
          dirty: false,
          label: 'test',
        }),
      })
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

  it('preserves an installed waiting update across an inconclusive check', async () => {
    const waiting = { postMessage: vi.fn() };
    serviceWorkerMocks.getRegistration.mockResolvedValueOnce({
      update: vi.fn().mockRejectedValue(new Error('update failed')),
      waiting,
    });
    vi.stubGlobal(
      'fetch',
      vi.fn()
        .mockRejectedValueOnce(new TypeError('offline'))
        .mockRejectedValueOnce(new TypeError('offline'))
    );

    const { checkNow, useAppUpdateMonitor } = await import('@/features/pwa/appUpdate');
    await checkNow();

    expect(useAppUpdateMonitor().available.value).toBe(true);

    serviceWorkerMocks.getRegistration.mockRejectedValueOnce(
      new TypeError('registration unavailable')
    );
    await checkNow();

    expect(useAppUpdateMonitor().available.value).toBe(true);
  });
});
