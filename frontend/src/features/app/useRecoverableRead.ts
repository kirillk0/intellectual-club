import { onBeforeUnmount } from 'vue';

import {
  beginLoadTask,
  startupLoadStartedAt,
  type LoadTaskHandle,
} from '@/features/app/loadCoordinator';
import {
  isTransientReadError,
  recoverableRetryDelayMs,
} from '@/features/app/recoverableReadPolicy';
import { subscribeRecoveryHeartbeat } from '@/features/app/recoveryHeartbeat';

type RecoverableReadContext = {
  signal: AbortSignal;
};

type RecoverableReadOptions = {
  key: string | (() => string);
  label?: string;
};

export type RecoverableReadController<T> = {
  run: (
    read: (context: RecoverableReadContext) => Promise<T>,
    options?: { restart?: boolean }
  ) => Promise<T>;
  cancel: () => void;
  dispose: () => void;
};

type SharedExecution<T> = {
  key: string;
  promise: Promise<T>;
  controller: AbortController;
  task: LoadTaskHandle;
  owners: Set<symbol>;
  wake: (() => void) | null;
  attempt: number;
  retrying: boolean;
  waitingForConnection: boolean;
  waitingForVisibility: boolean;
};

const activeExecutions = new Map<string, SharedExecution<unknown>>();

const isAbortError = (error: unknown) =>
  error != null &&
  typeof error === 'object' &&
  'name' in error &&
  (error as { name?: unknown }).name === 'AbortError';

const resolveKey = (value: RecoverableReadOptions['key']) =>
  typeof value === 'function' ? value() : value;

const createAbortError = () => new DOMException('The operation was aborted.', 'AbortError');

const registeredExecution = <T>(key: string) =>
  activeExecutions.get(key) as SharedExecution<T> | undefined;

const updateTask = (execution: SharedExecution<unknown>) => {
  execution.task.update({
    attempt: Math.max(1, execution.attempt),
    retrying: execution.retrying,
    waitingForConnection: execution.waitingForConnection,
    waitingForVisibility: execution.waitingForVisibility,
  });
};

subscribeRecoveryHeartbeat((pulse) => {
  for (const execution of activeExecutions.values()) {
    execution.waitingForConnection = pulse.onlineHint === false;
    execution.waitingForVisibility = !pulse.visible;
    updateTask(execution);
    execution.wake?.();
  }
});

const finishExecution = (execution: SharedExecution<unknown>, abort: boolean) => {
  if (abort) execution.controller.abort();
  execution.task.finish();
  if (activeExecutions.get(execution.key) === execution) {
    activeExecutions.delete(execution.key);
  }
};

const waitForNextAttempt = (
  execution: SharedExecution<unknown>,
  delayMs: number
): Promise<void> => {
  const { controller } = execution;
  if (controller.signal.aborted) return Promise.reject(createAbortError());

  return new Promise((resolve, reject) => {
    let timer: number | null = null;

    const cleanup = () => {
      if (timer !== null) window.clearTimeout(timer);
      controller.signal.removeEventListener('abort', abort);
      if (execution.wake === finish) execution.wake = null;
    };
    const finish = () => {
      cleanup();
      resolve();
    };
    const abort = () => {
      cleanup();
      reject(createAbortError());
    };

    execution.wake = finish;
    controller.signal.addEventListener('abort', abort, { once: true });
    execution.waitingForConnection = navigator.onLine === false;
    execution.waitingForVisibility = document.visibilityState === 'hidden';
    updateTask(execution);
    timer = window.setTimeout(finish, delayMs);
  });
};

const createExecution = <T>(
  options: RecoverableReadOptions,
  key: string,
  read: (context: RecoverableReadContext) => Promise<T>
) => {
  const controller = new AbortController();
  const task = beginLoadTask({
    key,
    stage: 'data',
    label: options.label,
    startedAt: startupLoadStartedAt(),
  });
  const execution: SharedExecution<T> = {
    key,
    promise: Promise.resolve(undefined as T),
    controller,
    task,
    owners: new Set(),
    wake: null,
    attempt: 0,
    retrying: false,
    waitingForConnection: navigator.onLine === false,
    waitingForVisibility: document.visibilityState === 'hidden',
  };

  execution.promise = Promise.resolve().then(async () => {
    let retryIndex = 0;

    try {
      for (;;) {
        if (controller.signal.aborted) throw createAbortError();

        execution.attempt += 1;
        execution.retrying = execution.attempt > 1;
        execution.waitingForConnection = false;
        execution.waitingForVisibility = false;
        updateTask(execution);

        try {
          const result = await read({ signal: controller.signal });
          if (controller.signal.aborted) throw createAbortError();
          return result;
        } catch (error) {
          if (controller.signal.aborted || isAbortError(error)) throw error;
          if (!isTransientReadError(error)) throw error;

          execution.retrying = true;
          execution.waitingForConnection = navigator.onLine === false;
          execution.waitingForVisibility = document.visibilityState === 'hidden';
          updateTask(execution);
          await waitForNextAttempt(
            execution,
            recoverableRetryDelayMs(retryIndex, error)
          );
          retryIndex += 1;
        }
      }
    } finally {
      finishExecution(execution, false);
    }
  });

  activeExecutions.set(key, execution as SharedExecution<unknown>);
  return execution;
};

export const createRecoverableRead = <T>(
  options: RecoverableReadOptions
): RecoverableReadController<T> => {
  const owner = Symbol('recoverable-read-owner');
  let disposed = false;
  let active: SharedExecution<T> | null = null;

  const detach = () => {
    if (!active) return;
    const execution = active;
    active = null;
    execution.owners.delete(owner);
    if (
      execution.owners.size === 0 &&
      activeExecutions.get(execution.key) === execution
    ) {
      finishExecution(execution, true);
    }
  };

  const attach = (execution: SharedExecution<T>) => {
    active = execution;
    execution.owners.add(owner);
    void execution.promise
      .finally(() => {
        if (active === execution) active = null;
      })
      .catch(() => undefined);
    return execution.promise;
  };

  const run: RecoverableReadController<T>['run'] = (read, runOptions = {}) => {
    if (disposed) return Promise.reject(createAbortError());
    const key = resolveKey(options.key);

    if (runOptions.restart) {
      const existing = registeredExecution<T>(key);
      const exclusivelyOwned =
        existing &&
        (existing.owners.size === 0 ||
          (existing.owners.size === 1 && existing.owners.has(owner)));
      if (existing && exclusivelyOwned) {
        finishExecution(existing, true);
        if (active === existing) active = null;
      } else if (existing) {
        if (active && active !== existing) detach();
        return attach(existing);
      }
    } else if (
      active?.key === key &&
      registeredExecution<T>(key) === active
    ) {
      return active.promise;
    }

    if (active) detach();
    const existing = registeredExecution<T>(key);
    return attach(existing || createExecution(options, key, read));
  };

  const dispose = () => {
    if (disposed) return;
    disposed = true;
    detach();
  };

  return {
    run,
    cancel: detach,
    dispose,
  };
};

export const useRecoverableRead = <T>(options: RecoverableReadOptions) => {
  const controller = createRecoverableRead<T>(options);
  onBeforeUnmount(controller.dispose);
  return controller;
};
