import type { QueryClient } from '@tanstack/vue-query';

import {
  beginLoadTask,
  startupLoadStartedAt,
  type LoadTaskHandle,
} from '@/features/app/loadCoordinator';

type InitialQueryState = {
  active: boolean;
  attempt: number;
  paused: boolean;
};

const activeInitialQueries = (queryClient: QueryClient) =>
  queryClient
    .getQueryCache()
    .getAll()
    .filter(
      (query) =>
        query.getObserversCount() > 0 &&
        query.state.status === 'pending' &&
        query.state.fetchStatus !== 'idle'
    );

const initialQueryState = (queryClient: QueryClient): InitialQueryState => {
  const queries = activeInitialQueries(queryClient);

  return {
    active: queries.length > 0,
    attempt:
      queries.reduce(
        (highest, query) => Math.max(highest, query.state.fetchFailureCount + 1),
        1
      ),
    paused: queries.some((query) => query.state.fetchStatus === 'paused'),
  };
};

export const setupInitialQueryLoadBridge = (queryClient: QueryClient) => {
  let task: LoadTaskHandle | null = null;
  let wakingQueries = false;
  let highestAttempt = 1;
  let wakePromise: Promise<void> | null = null;

  const sync = () => {
    const state = initialQueryState(queryClient);
    if (!state.active) {
      if (wakingQueries) return;
      task?.finish();
      task = null;
      highestAttempt = 1;
      return;
    }

    if (!task) {
      task = beginLoadTask({
        key: 'server-state:initial',
        stage: 'data',
        startedAt: startupLoadStartedAt(),
      });
    }

    highestAttempt = Math.max(highestAttempt, state.attempt);
    task.update({
      attempt: highestAttempt,
      retrying: highestAttempt > 1,
      waitingForConnection: state.paused && navigator.onLine === false,
      waitingForVisibility:
        state.paused && document.visibilityState === 'hidden',
    });
  };

  const unsubscribe = queryClient.getQueryCache().subscribe(sync);
  const syncOnEnvironmentChange = () => {
    if (
      navigator.onLine === false ||
      document.visibilityState === 'hidden'
    ) {
      sync();
      return;
    }

    const retryingQueries = activeInitialQueries(queryClient).filter(
      (query) => query.state.fetchFailureCount > 0
    );
    if (!retryingQueries.length || wakePromise) {
      sync();
      return;
    }

    wakingQueries = true;
    wakePromise = Promise.all(
      retryingQueries.map(async (query) => {
        await query.cancel({ silent: true });
        if (
          navigator.onLine === false ||
          document.visibilityState === 'hidden' ||
          query.getObserversCount() === 0
        ) {
          return;
        }
        void query.fetch().catch(() => undefined);
      })
    )
      .then(() => undefined)
      .finally(() => {
        wakingQueries = false;
        wakePromise = null;
        sync();
      });
  };

  window.addEventListener('online', syncOnEnvironmentChange);
  window.addEventListener('offline', syncOnEnvironmentChange);
  window.addEventListener('focus', syncOnEnvironmentChange);
  window.addEventListener('pageshow', syncOnEnvironmentChange);
  document.addEventListener('visibilitychange', syncOnEnvironmentChange);
  sync();

  return () => {
    unsubscribe();
    window.removeEventListener('online', syncOnEnvironmentChange);
    window.removeEventListener('offline', syncOnEnvironmentChange);
    window.removeEventListener('focus', syncOnEnvironmentChange);
    window.removeEventListener('pageshow', syncOnEnvironmentChange);
    document.removeEventListener('visibilitychange', syncOnEnvironmentChange);
    task?.finish();
    task = null;
  };
};
