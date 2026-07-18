describe('recovery heartbeat', () => {
  beforeEach(() => {
    vi.resetModules();
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('uses one set of browser listeners and exposes explicit wake requests', async () => {
    const addWindowListener = vi.spyOn(window, 'addEventListener');
    const addDocumentListener = vi.spyOn(document, 'addEventListener');
    const {
      requestRecoveryNow,
      subscribeRecoveryHeartbeat,
    } = await import('@/features/app/recoveryHeartbeat');
    const first = vi.fn();
    const second = vi.fn();

    const unsubscribeFirst = subscribeRecoveryHeartbeat(first, { immediate: true });
    const unsubscribeSecond = subscribeRecoveryHeartbeat(second);

    expect(first).toHaveBeenCalledWith(
      expect.objectContaining({
        reason: 'subscribe',
        visible: true,
      })
    );
    expect(
      addWindowListener.mock.calls.filter(([event]) => event === 'focus')
    ).toHaveLength(1);
    expect(
      addDocumentListener.mock.calls.filter(([event]) => event === 'resume')
    ).toHaveLength(1);

    window.dispatchEvent(new Event('focus'));
    document.dispatchEvent(new Event('resume'));
    requestRecoveryNow();

    expect(first.mock.calls.map(([pulse]) => pulse.reason)).toEqual(
      expect.arrayContaining(['focus', 'resume', 'manual'])
    );
    expect(second.mock.calls.map(([pulse]) => pulse.reason)).toEqual(
      expect.arrayContaining(['focus', 'resume', 'manual'])
    );

    unsubscribeFirst();
    unsubscribeSecond();
  });

  it('keeps a timer armed while hidden so a missed wake event cannot strand recovery', async () => {
    let visibility: DocumentVisibilityState = 'visible';
    vi.spyOn(document, 'visibilityState', 'get').mockImplementation(() => visibility);
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false);
    const { subscribeRecoveryHeartbeat } = await import(
      '@/features/app/recoveryHeartbeat'
    );
    const listener = vi.fn();
    const unsubscribe = subscribeRecoveryHeartbeat(listener);

    await vi.advanceTimersByTimeAsync(9_999);
    expect(listener).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(listener).toHaveBeenLastCalledWith(
      expect.objectContaining({
        reason: 'interval',
        visible: true,
        onlineHint: false,
      })
    );

    visibility = 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
    listener.mockClear();

    await vi.advanceTimersByTimeAsync(29_999);
    expect(listener).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(listener).toHaveBeenLastCalledWith(
      expect.objectContaining({ reason: 'interval', visible: false })
    );

    listener.mockClear();
    visibility = 'visible';
    await vi.advanceTimersByTimeAsync(30_000);
    expect(listener).toHaveBeenLastCalledWith(
      expect.objectContaining({ reason: 'interval', visible: true })
    );

    unsubscribe();
  });
});
