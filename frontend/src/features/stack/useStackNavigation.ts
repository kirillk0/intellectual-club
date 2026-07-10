import { computed } from 'vue';
import { useRouter, type NavigationFailure, type RouteLocationRaw } from 'vue-router';
import {
  useNavigationStack,
  type StackNavigationResult,
  type StackResultController,
} from '@/features/stack/navigationStack';

const withStackState = (to: RouteLocationRaw): RouteLocationRaw => {
  if (typeof to === 'string') {
    return { path: to, state: { stack: true } };
  }
  const raw: any = { ...to };
  raw.state = { ...(raw.state || {}), stack: true };
  return raw as RouteLocationRaw;
};

export function useStackNavigation() {
  const router = useRouter();
  const stack = useNavigationStack();

  const isStackActive = computed(() => stack.active.value);

  const navigateToNewLayer = async (
    to: RouteLocationRaw,
    resultController?: StackResultController
  ): Promise<NavigationFailure | void> => {
    const scrollTop =
      document.scrollingElement?.scrollTop ?? document.documentElement.scrollTop ?? window.scrollY ?? 0;
    const pendingPushId = stack.markPendingPush(scrollTop, resultController);
    try {
      const failure = await router.push(withStackState(to));
      if (failure) stack.cancelPendingPush(pendingPushId);
      return failure;
    } catch (error) {
      stack.cancelPendingPush(pendingPushId);
      throw error;
    }
  };

  const open = (to: RouteLocationRaw) => navigateToNewLayer(to);

  const openForResult = async <T>(to: RouteLocationRaw): Promise<StackNavigationResult<T>> => {
    const { controller, promise } = stack.createResultController<T>();
    try {
      await navigateToNewLayer(to, controller);
    } catch {
      controller.cancel();
    }
    return promise;
  };

  const push = (to: RouteLocationRaw) => {
    if (stack.active.value) return router.push(withStackState(to));
    return router.push(to);
  };

  const replace = (to: RouteLocationRaw) => {
    if (stack.active.value) return router.replace(withStackState(to));
    return router.replace(to);
  };

  const close = () => router.back();

  const reset = () => stack.reset();
  const setLayerResult = <T>(value: T) => stack.setLayerResult(value);
  const updateLayerResult = <T>(updater: (current: T | undefined) => T) => stack.updateLayerResult(updater);

  return {
    open,
    openForResult,
    push,
    replace,
    close,
    reset,
    setLayerResult,
    updateLayerResult,
    isStackActive,
  };
}

export type { StackNavigationResult };
