describe('load coordinator startup handoff', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-07-17T10:00:00Z'));
  });

  afterEach(() => {
    delete window.__IC_BOOTSTRAP__;
    vi.useRealTimers();
    vi.resetModules();
  });

  it('keeps the navigation start time for critical reads mounted after router readiness', async () => {
    const startAt = Date.now() - 1_900;
    const state: IcBootstrapState = {
      buildId: 'test',
      startAt,
      stage: 'route',
      delayed: false,
      online: true,
      attempt: 1,
      update(patch) {
        Object.assign(state, patch);
      },
    };
    window.__IC_BOOTSTRAP__ = state;

    const coordinator = await import('@/features/app/loadCoordinator');
    coordinator.setBootstrapLoadStage('ready');

    expect(coordinator.startupLoadStartedAt()).toBe(startAt);
    const dataTask = coordinator.beginLoadTask({
      key: 'background-data',
      stage: 'data',
      startedAt: startAt,
    });
    expect(coordinator.useLoadCoordinator().status.value).toBeNull();

    const routeTask = coordinator.beginLoadTask({
      key: 'next-route',
      stage: 'route',
      startedAt: startAt,
    });
    expect(coordinator.useLoadCoordinator().status.value?.stage).toBe('route');
    routeTask.finish();
    dataTask.finish();

    await vi.advanceTimersByTimeAsync(0);
    expect(coordinator.startupLoadStartedAt()).toBe(Date.now());
  });
});
