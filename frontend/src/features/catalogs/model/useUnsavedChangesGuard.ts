import { onBeforeUnmount, onMounted, type ComputedRef, type Ref } from 'vue';
import {
  onBeforeRouteLeave,
  onBeforeRouteUpdate,
  type RouteLocationNormalizedLoaded,
} from 'vue-router';
import { useNavigationStack } from '@/features/stack/navigationStack';

type MaybeRef<T> = Ref<T> | ComputedRef<T>;

export function useUnsavedChangesGuard(dirty: MaybeRef<boolean>) {
  const message = 'You have unsaved changes. Leave without saving?';
  const stack = useNavigationStack();
  const isStackNavigation = (target: RouteLocationNormalizedLoaded) =>
    Boolean((target as any)?.state?.stack || stack.pendingPush.value !== null);

  const beforeUnload = (event: BeforeUnloadEvent) => {
    if (!dirty.value) return;
    event.preventDefault();
    event.returnValue = '';
  };

  onMounted(() => {
    window.addEventListener('beforeunload', beforeUnload);
  });

  onBeforeRouteLeave((to) => {
    if (isStackNavigation(to)) return true;
    if (!dirty.value) return true;
    return window.confirm(message);
  });

  onBeforeRouteUpdate((to: RouteLocationNormalizedLoaded, from: RouteLocationNormalizedLoaded) => {
    if (isStackNavigation(to)) return true;
    if (!dirty.value) return true;
    if (to.path === from.path) return true;
    return window.confirm(message);
  });

  onBeforeUnmount(() => {
    window.removeEventListener('beforeunload', beforeUnload);
  });
}
