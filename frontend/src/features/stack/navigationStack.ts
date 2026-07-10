import { computed, ref } from 'vue';
import type { RouteLocationNormalizedLoaded } from 'vue-router';

export type StackNavigationResult<T> = { status: 'completed'; value: T } | { status: 'cancelled' };

export type StackResultController = {
  setResult: (value: unknown) => boolean;
  updateResult: (updater: (current: unknown) => unknown) => boolean;
  complete: () => void;
  cancel: () => void;
};

type StackEntry = {
  route: RouteLocationNormalizedLoaded;
  scrollY: number;
  resultController?: StackResultController;
};

type PendingStackPush = {
  id: number;
  scrollY: number;
  resultController?: StackResultController;
};

const stack = ref<StackEntry[]>([]);
const pendingPush = ref<PendingStackPush | null>(null);
let nextPendingPushId = 1;

const active = computed(() => stack.value.length > 0);
const top = computed(() => (stack.value.length ? stack.value[stack.value.length - 1] : null));

const cloneRoute = (route: RouteLocationNormalizedLoaded) =>
  ({
    ...route,
    params: { ...(route.params ?? {}) },
    query: { ...(route.query ?? {}) },
  }) as RouteLocationNormalizedLoaded;

const createResultController = <T>() => {
  let resolveResult: (result: StackNavigationResult<T>) => void = () => undefined;
  let resultSet = false;
  let resultValue: unknown;
  let settled = false;

  const promise = new Promise<StackNavigationResult<T>>((resolve) => {
    resolveResult = resolve;
  });

  const controller: StackResultController = {
    setResult(value) {
      if (settled) return false;
      resultSet = true;
      resultValue = value;
      return true;
    },
    updateResult(updater) {
      if (settled) return false;
      resultValue = updater(resultSet ? resultValue : undefined);
      resultSet = true;
      return true;
    },
    complete() {
      if (settled) return;
      settled = true;
      if (resultSet) {
        resolveResult({ status: 'completed', value: resultValue as T });
      } else {
        resolveResult({ status: 'cancelled' });
      }
    },
    cancel() {
      if (settled) return;
      settled = true;
      resolveResult({ status: 'cancelled' });
    },
  };

  return { controller, promise };
};

const cancelPendingPush = (id?: number) => {
  if (id !== undefined && pendingPush.value?.id !== id) return false;
  const pending = pendingPush.value;
  if (!pending) return false;
  pendingPush.value = null;
  pending.resultController?.cancel();
  return true;
};

const markPendingPush = (scrollY: number, resultController?: StackResultController) => {
  cancelPendingPush();
  const id = nextPendingPushId++;
  pendingPush.value = { id, scrollY, resultController };
  return id;
};

const commitPendingPush = (route: RouteLocationNormalizedLoaded) => {
  const pending = pendingPush.value;
  if (!pending) return null;

  stack.value.push({
    route: cloneRoute(route),
    scrollY: pending.scrollY,
    resultController: pending.resultController,
  });
  pendingPush.value = null;
  return pending;
};

const pop = () => {
  const entry = stack.value.pop();
  entry?.resultController?.complete();
  return entry;
};

const setLayerResult = <T>(value: T) => top.value?.resultController?.setResult(value) ?? false;
const updateLayerResult = <T>(updater: (current: T | undefined) => T) =>
  top.value?.resultController?.updateResult((current) => updater(current as T | undefined)) ?? false;

const reset = () => {
  cancelPendingPush();
  for (const entry of stack.value) {
    entry.resultController?.cancel();
  }
  stack.value = [];
};

export function useNavigationStack() {
  return {
    stack,
    pendingPush,
    active,
    top,
    createResultController,
    markPendingPush,
    cancelPendingPush,
    commitPendingPush,
    pop,
    setLayerResult,
    updateLayerResult,
    reset,
  };
}
