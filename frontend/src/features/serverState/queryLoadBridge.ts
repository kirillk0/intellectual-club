import { focusManager, type QueryClient } from '@tanstack/vue-query';

import {
  beginLoadTask,
  startupLoadStartedAt,
  type LoadTaskHandle,
} from '@/features/app/loadCoordinator';
import { subscribeRecoveryHeartbeat } from '@/features/app/recoveryHeartbeat';

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
  let highestAttempt = 1;
  let visible = document.visibilityState !== 'hidden';
  let onlineHint = navigator.onLine !== false;

  const sync = () => {
    const state = initialQueryState(queryClient);
    if (!state.active) {
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
      waitingForConnection: state.paused && !onlineHint,
      waitingForVisibility: state.paused && !visible,
    });
  };

  const unsubscribe = queryClient.getQueryCache().subscribe(sync);
  const unsubscribeHeartbeat = subscribeRecoveryHeartbeat(
    (pulse) => {
      visible = pulse.visible;
      onlineHint = pulse.onlineHint;
      // TanStack pauses retryers on focus in addition to network state.
      // A periodic pulse must release that pause even when WebKit reports
      // stale visibility after a PWA wake.
      focusManager.setFocused(true);
      if (pulse.reason === 'manual') {
        void queryClient
          .refetchQueries(
            { type: 'active' },
            { cancelRefetch: true, throwOnError: false }
          )
          .catch(() => undefined);
      }
      sync();
    },
    { immediate: true }
  );
  sync();

  return () => {
    unsubscribe();
    unsubscribeHeartbeat();
    focusManager.setFocused(undefined);
    task?.finish();
    task = null;
  };
};
