import { computed } from 'vue';
import { useRouter, type RouteLocationRaw } from 'vue-router';
import { useNavigationStack } from '@/features/stack/navigationStack';

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

  const open = async (to: RouteLocationRaw) => {
    const scrollTop =
      document.scrollingElement?.scrollTop ?? document.documentElement.scrollTop ?? window.scrollY ?? 0;
    stack.markPendingPush(scrollTop);
    try {
      await router.push(withStackState(to));
    } catch (error) {
      stack.clearPendingPush();
      throw error;
    }
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

  return {
    open,
    push,
    replace,
    close,
    reset,
    isStackActive,
  };
}

