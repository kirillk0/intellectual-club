import { focusManager, type QueryClient } from '@tanstack/vue-query';

const loadCoordinatorMocks = vi.hoisted(() => ({
  begin: vi.fn(),
  startupStartedAt: vi.fn(() => 1_000),
  update: vi.fn(),
  finish: vi.fn(),
}));

const heartbeatMocks = vi.hoisted(() => ({
  listeners: [] as Array<(pulse: {
    reason: 'subscribe' | 'manual' | 'interval';
    visible: boolean;
    onlineHint: boolean;
    at: number;
  }) => void>,
  subscribe: vi.fn(),
  unsubscribe: vi.fn(),
}));

vi.mock('@/features/app/loadCoordinator', () => ({
  beginLoadTask: loadCoordinatorMocks.begin,
  startupLoadStartedAt: loadCoordinatorMocks.startupStartedAt,
}));
vi.mock('@/features/app/recoveryHeartbeat', () => ({
  subscribeRecoveryHeartbeat: heartbeatMocks.subscribe,
}));

import { setupInitialQueryLoadBridge } from '@/features/serverState/queryLoadBridge';

describe('initial query load bridge', () => {
  beforeEach(() => {
    loadCoordinatorMocks.begin.mockReturnValue({
      update: loadCoordinatorMocks.update,
      finish: loadCoordinatorMocks.finish,
    });
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true);
    vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible');
    heartbeatMocks.listeners.length = 0;
    heartbeatMocks.unsubscribe.mockReset();
    heartbeatMocks.subscribe.mockImplementation((listener, options) => {
      heartbeatMocks.listeners.push(listener);
      if (options?.immediate) {
        listener({
          reason: 'subscribe',
          visible: true,
          onlineHint: true,
          at: Date.now(),
        });
      }
      return heartbeatMocks.unsubscribe;
    });
  });

  it('tracks only observed initial reads and excludes background refreshes', () => {
    const listeners = new Set<() => void>();
    const query = {
      observers: 0,
      getObserversCount() {
        return this.observers;
      },
      state: {
        status: 'pending',
        fetchStatus: 'idle',
        fetchFailureCount: 0,
      },
      cancel: vi.fn(),
      fetch: vi.fn().mockResolvedValue(undefined),
    };
    const queryCache = {
      getAll: () => [query],
      subscribe: (listener: () => void) => {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
    };
    const queryClient = {
      getQueryCache: () => queryCache,
      refetchQueries: vi.fn().mockResolvedValue(undefined),
    } as unknown as QueryClient;
    const emit = () => listeners.forEach((listener) => listener());

    const cleanup = setupInitialQueryLoadBridge(queryClient);
    expect(loadCoordinatorMocks.begin).not.toHaveBeenCalled();

    query.observers = 1;
    query.state.fetchStatus = 'fetching';
    emit();

    expect(loadCoordinatorMocks.begin).toHaveBeenCalledWith({
      key: 'server-state:initial',
      stage: 'data',
      startedAt: 1_000,
    });
    expect(loadCoordinatorMocks.update).toHaveBeenLastCalledWith({
      attempt: 1,
      retrying: false,
      waitingForConnection: false,
      waitingForVisibility: false,
    });

    query.state.fetchFailureCount = 1;
    emit();
    expect(loadCoordinatorMocks.update).toHaveBeenLastCalledWith(
      expect.objectContaining({ attempt: 2, retrying: true })
    );

    query.state.status = 'success';
    emit();
    expect(loadCoordinatorMocks.finish).toHaveBeenCalledTimes(1);

    query.state.status = 'pending';
    query.state.fetchStatus = 'fetching';
    query.observers = 0;
    emit();
    expect(loadCoordinatorMocks.begin).toHaveBeenCalledTimes(1);

    cleanup();
  });

  it('lets TanStack own retries and uses heartbeat to release its focus manager', () => {
    const listeners = new Set<() => void>();
    const query = {
      getObserversCount: () => 1,
      state: {
        status: 'pending',
        fetchStatus: 'paused',
        fetchFailureCount: 2,
      },
      cancel: vi.fn(),
      fetch: vi.fn(),
    };
    const queryCache = {
      getAll: () => [query],
      subscribe: (listener: () => void) => {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
    };
    const queryClient = {
      getQueryCache: () => queryCache,
      refetchQueries: vi.fn().mockResolvedValue(undefined),
    } as unknown as QueryClient;
    const setFocused = vi.spyOn(focusManager, 'setFocused');

    const cleanup = setupInitialQueryLoadBridge(queryClient);
    heartbeatMocks.listeners[0]?.({
      reason: 'interval',
      visible: false,
      onlineHint: false,
      at: Date.now(),
    });
    heartbeatMocks.listeners[0]?.({
      reason: 'interval',
      visible: true,
      onlineHint: false,
      at: Date.now(),
    });

    expect(setFocused).toHaveBeenCalledWith(true);
    expect(setFocused).not.toHaveBeenCalledWith(false);
    expect(query.cancel).not.toHaveBeenCalled();
    expect(query.fetch).not.toHaveBeenCalled();

    heartbeatMocks.listeners[0]?.({
      reason: 'manual',
      visible: true,
      onlineHint: false,
      at: Date.now(),
    });
    expect(queryClient.refetchQueries).toHaveBeenCalledWith(
      { type: 'active' },
      { cancelRefetch: true, throwOnError: false }
    );
    cleanup();
    expect(heartbeatMocks.unsubscribe).toHaveBeenCalledTimes(1);
  });
});
