export {};

const heartbeatMocks = vi.hoisted(() => ({
  listener: null as null | ((pulse: {
    reason: 'interval';
    visible: boolean;
    onlineHint: boolean;
    at: number;
  }) => void),
  subscribe: vi.fn(),
  unsubscribe: vi.fn(),
}));

const serviceWorkerMocks = vi.hoisted(() => ({
  getRegistration: vi.fn(),
}));

vi.mock('@/features/app/recoveryHeartbeat', () => ({
  subscribeRecoveryHeartbeat: heartbeatMocks.subscribe,
}));

vi.mock('@/features/pwa/serviceWorker', () => ({
  getServiceWorkerRegistration: serviceWorkerMocks.getRegistration,
}));

describe('app update heartbeat', () => {
  beforeEach(() => {
    vi.resetModules();
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-07-18T10:00:00Z'));
    heartbeatMocks.listener = null;
    heartbeatMocks.unsubscribe.mockReset();
    heartbeatMocks.subscribe.mockImplementation((listener) => {
      heartbeatMocks.listener = listener;
      return heartbeatMocks.unsubscribe;
    });
    serviceWorkerMocks.getRegistration.mockResolvedValue({
      update: vi.fn().mockResolvedValue(undefined),
      waiting: null,
    });
    Object.defineProperty(navigator, 'serviceWorker', {
      configurable: true,
      value: {},
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
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('uses visible heartbeat pulses with a five minute throttle', async () => {
    const { useAppUpdateMonitor } = await import('@/features/pwa/appUpdate');
    const monitor = useAppUpdateMonitor();

    monitor.start();
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
    expect(heartbeatMocks.subscribe).toHaveBeenCalledTimes(1);

    vi.setSystemTime(new Date('2026-07-18T10:04:59Z'));
    heartbeatMocks.listener?.({
      reason: 'interval',
      visible: true,
      onlineHint: true,
      at: Date.now(),
    });
    await Promise.resolve();
    expect(fetch).toHaveBeenCalledTimes(1);

    vi.setSystemTime(new Date('2026-07-18T10:05:00Z'));
    heartbeatMocks.listener?.({
      reason: 'interval',
      visible: true,
      onlineHint: false,
      at: Date.now(),
    });
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(2));

    vi.setSystemTime(new Date('2026-07-18T10:10:00Z'));
    heartbeatMocks.listener?.({
      reason: 'interval',
      visible: false,
      onlineHint: true,
      at: Date.now(),
    });
    await Promise.resolve();
    expect(fetch).toHaveBeenCalledTimes(2);

    monitor.stop();
    expect(heartbeatMocks.unsubscribe).toHaveBeenCalledTimes(1);
  });
});
