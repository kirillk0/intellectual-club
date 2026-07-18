import type { QueryClient } from '@tanstack/vue-query';

const loadCoordinatorMocks = vi.hoisted(() => ({
  begin: vi.fn(),
  startupStartedAt: vi.fn(() => 1_000),
  update: vi.fn(),
  finish: vi.fn(),
}));

vi.mock('@/features/app/loadCoordinator', () => ({
  beginLoadTask: loadCoordinatorMocks.begin,
  startupLoadStartedAt: loadCoordinatorMocks.startupStartedAt,
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

  it('waits for cancellation before waking a failed initial query', async () => {
    const listeners = new Set<() => void>();
    let resolveCancel!: () => void;
    const cancelFinished = new Promise<void>((resolve) => {
      resolveCancel = resolve;
    });
    const query = {
      getObserversCount: () => 1,
      state: {
        status: 'pending',
        fetchStatus: 'paused',
        fetchFailureCount: 2,
      },
      cancel: vi.fn(() => {
        query.state.fetchStatus = 'idle';
        listeners.forEach((listener) => listener());
        return cancelFinished;
      }),
      fetch: vi.fn(() => {
        query.state.fetchStatus = 'fetching';
        return Promise.resolve(undefined);
      }),
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
    } as unknown as QueryClient;

    const cleanup = setupInitialQueryLoadBridge(queryClient);
    window.dispatchEvent(new Event('online'));

    expect(query.cancel).toHaveBeenCalledWith({ silent: true });
    expect(query.fetch).not.toHaveBeenCalled();
    expect(loadCoordinatorMocks.finish).not.toHaveBeenCalled();

    resolveCancel();
    await vi.waitFor(() => expect(query.fetch).toHaveBeenCalledTimes(1));
    expect(query.fetch).toHaveBeenCalledTimes(1);
    expect(loadCoordinatorMocks.update).toHaveBeenLastCalledWith(
      expect.objectContaining({ attempt: 3, retrying: true })
    );
    cleanup();
  });
});
