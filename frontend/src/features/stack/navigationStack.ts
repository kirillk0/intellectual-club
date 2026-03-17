import { computed, ref } from 'vue';
import type { RouteLocationNormalizedLoaded } from 'vue-router';

type StackEntry = {
  route: RouteLocationNormalizedLoaded;
  scrollY: number;
};

const stack = ref<StackEntry[]>([]);
const pendingPush = ref<number | null>(null);

const active = computed(() => stack.value.length > 0);
const top = computed(() => (stack.value.length ? stack.value[stack.value.length - 1] : null));

const cloneRoute = (route: RouteLocationNormalizedLoaded) =>
  ({
    ...route,
    params: { ...(route.params ?? {}) },
    query: { ...(route.query ?? {}) },
  }) as RouteLocationNormalizedLoaded;

const markPendingPush = (scrollY: number) => {
  pendingPush.value = scrollY;
};

const clearPendingPush = () => {
  pendingPush.value = null;
};

const push = (route: RouteLocationNormalizedLoaded, scrollY: number) => {
  stack.value.push({ route: cloneRoute(route), scrollY });
};

const pop = () => stack.value.pop();

const reset = () => {
  stack.value = [];
  pendingPush.value = null;
};

export function useNavigationStack() {
  return {
    stack,
    pendingPush,
    active,
    top,
    markPendingPush,
    clearPendingPush,
    push,
    pop,
    reset,
  };
}

