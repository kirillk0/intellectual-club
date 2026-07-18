import { computed, onBeforeUnmount, ref, shallowRef, type Ref } from 'vue';

import {
  beginLoadTask,
  type LoadStage,
  type LoadTaskHandle,
} from '@/features/app/loadCoordinator';
import {
  isTransientReadError,
  recoverableRetryDelayMs,
  retryAfterDelayMs,
} from '@/features/app/recoverableReadPolicy';

export { isTransientReadError, retryAfterDelayMs };

type RecoverableReadContext = {
  signal: AbortSignal;
  attempt: number;
};

export type RecoverableReadOptions = {
  key: string | (() => string);
  stage?: Exclude<LoadStage, 'ready'>;
  label?: string;
  startedAt?: () => number;
  retryDelaysMs?: readonly number[];
  random?: () => number;
};

export type RecoverableReadController<T> = {
  run: (
    read: (context: RecoverableReadContext) => Promise<T>,
    options?: { restart?: boolean }
  ) => Promise<T>;
  cancel: () => void;
  dispose: () => void;
  attempt: Readonly<Ref<number>>;
  retrying: Readonly<Ref<boolean>>;
  waitingForConnection: Readonly<Ref<boolean>>;
  waitingForVisibility: Readonly<Ref<boolean>>;
};

type SharedExecution<T> = {
  key: string;
  promise: Promise<T>;
  controller: AbortController;
  task: LoadTaskHandle;
  owners: Set<symbol>;
  wake: (() => void) | null;
  attempt: Ref<number>;
  retrying: Ref<boolean>;
  waitingForConnection: Ref<boolean>;
  waitingForVisibility: Ref<boolean>;
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
    attempt: Math.max(1, execution.attempt.value),
    retrying: execution.retrying.value,
    waitingForConnection: execution.waitingForConnection.value,
    waitingForVisibility: execution.waitingForVisibility.value,
  });
};

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

    if (navigator.onLine === false || document.visibilityState === 'hidden') {
      execution.waitingForConnection.value = navigator.onLine === false;
      execution.waitingForVisibility.value = document.visibilityState === 'hidden';
      updateTask(execution);
      return;
    }

    execution.waitingForConnection.value = false;
    execution.waitingForVisibility.value = false;
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
    stage: options.stage || 'data',
    label: options.label,
    startedAt: options.startedAt?.() ?? Date.now(),
  });
  const execution: SharedExecution<T> = {
    key,
    promise: Promise.resolve(undefined as T),
    controller,
    task,
    owners: new Set(),
    wake: null,
    attempt: ref(0),
    retrying: ref(false),
    waitingForConnection: ref(navigator.onLine === false),
    waitingForVisibility: ref(document.visibilityState === 'hidden'),
  };
  const retryDelays = options.retryDelaysMs?.length
    ? options.retryDelaysMs
    : undefined;
  const random = options.random || Math.random;

  execution.promise = Promise.resolve().then(async () => {
    let retryIndex = 0;

    try {
      for (;;) {
        if (controller.signal.aborted) throw createAbortError();
        if (navigator.onLine === false || document.visibilityState === 'hidden') {
          await waitForNextAttempt(execution, 0);
        }

        execution.attempt.value += 1;
        execution.retrying.value = execution.attempt.value > 1;
        execution.waitingForConnection.value = false;
        execution.waitingForVisibility.value = false;
        updateTask(execution);

        try {
          const result = await read({
            signal: controller.signal,
            attempt: execution.attempt.value,
          });
          if (controller.signal.aborted) throw createAbortError();
          return result;
        } catch (error) {
          if (controller.signal.aborted || isAbortError(error)) throw error;
          if (!isTransientReadError(error)) throw error;

          execution.retrying.value = true;
          execution.waitingForConnection.value = navigator.onLine === false;
          execution.waitingForVisibility.value = document.visibilityState === 'hidden';
          updateTask(execution);
          await waitForNextAttempt(
            execution,
            recoverableRetryDelayMs(retryIndex, error, retryDelays, random)
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
  const active = shallowRef<SharedExecution<T> | null>(null);

  const detach = () => {
    if (!active.value) return;
    const execution = active.value;
    active.value = null;
    execution.owners.delete(owner);
    if (
      execution.owners.size === 0 &&
      activeExecutions.get(execution.key) === execution
    ) {
      finishExecution(execution, true);
    }
  };

  const attach = (execution: SharedExecution<T>) => {
    active.value = execution;
    execution.owners.add(owner);
    void execution.promise
      .finally(() => {
        if (active.value === execution) active.value = null;
      })
      .catch(() => undefined);
    return execution.promise;
  };

  const wake = () => {
    const execution = active.value;
    if (!execution || navigator.onLine === false || document.visibilityState === 'hidden') {
      return;
    }
    execution.waitingForConnection.value = false;
    execution.waitingForVisibility.value = false;
    updateTask(execution);
    execution.wake?.();
  };

  const handleOffline = () => {
    if (!active.value) return;
    active.value.waitingForConnection.value = true;
    updateTask(active.value);
  };

  const handleVisibilityChange = () => {
    if (!active.value) return;
    if (document.visibilityState === 'hidden') {
      active.value.waitingForVisibility.value = true;
      active.value.waitingForConnection.value = navigator.onLine === false;
      updateTask(active.value);
      return;
    }
    wake();
  };

  window.addEventListener('online', wake);
  window.addEventListener('focus', wake);
  window.addEventListener('pageshow', wake);
  window.addEventListener('offline', handleOffline);
  document.addEventListener('visibilitychange', handleVisibilityChange);

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
        if (active.value === existing) active.value = null;
      } else if (existing) {
        if (active.value && active.value !== existing) detach();
        return attach(existing);
      }
    } else if (
      active.value?.key === key &&
      registeredExecution<T>(key) === active.value
    ) {
      return active.value.promise;
    }

    if (active.value) detach();
    const existing = registeredExecution<T>(key);
    return attach(existing || createExecution(options, key, read));
  };

  const dispose = () => {
    if (disposed) return;
    disposed = true;
    detach();
    window.removeEventListener('online', wake);
    window.removeEventListener('focus', wake);
    window.removeEventListener('pageshow', wake);
    window.removeEventListener('offline', handleOffline);
    document.removeEventListener('visibilitychange', handleVisibilityChange);
  };

  const idleAttempt = ref(0);
  const idleState = ref(false);

  return {
    run,
    cancel: detach,
    dispose,
    attempt: computed(() => active.value?.attempt.value ?? idleAttempt.value),
    retrying: computed(() => active.value?.retrying.value ?? idleState.value),
    waitingForConnection: computed(
      () => active.value?.waitingForConnection.value ?? idleState.value
    ),
    waitingForVisibility: computed(
      () => active.value?.waitingForVisibility.value ?? idleState.value
    ),
  };
};

export const runRecoverableRead = async <T>(
  options: RecoverableReadOptions,
  read: (context: RecoverableReadContext) => Promise<T>
) => {
  const controller = createRecoverableRead<T>(options);
  try {
    return await controller.run(read);
  } finally {
    controller.dispose();
  }
};

export const useRecoverableRead = <T>(options: RecoverableReadOptions) => {
  const controller = createRecoverableRead<T>(options);
  onBeforeUnmount(controller.dispose);
  return controller;
};
