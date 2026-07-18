import {
  onScopeDispose,
  readonly,
  ref,
  toValue,
  watch,
  type MaybeRefOrGetter,
} from 'vue';

export const LOADING_NOTICE_DELAY_MS = 2_000;

type DelayedVisibilityOptions = {
  delayMs?: number;
  showImmediately?: MaybeRefOrGetter<boolean>;
};

export function useDelayedVisibility(
  active: MaybeRefOrGetter<boolean>,
  {
    delayMs = LOADING_NOTICE_DELAY_MS,
    showImmediately = false,
  }: DelayedVisibilityOptions = {}
) {
  const visible = ref(false);
  let timeoutId: number | null = null;

  const clearTimer = () => {
    if (timeoutId === null) return;
    window.clearTimeout(timeoutId);
    timeoutId = null;
  };

  watch(
    () => [Boolean(toValue(active)), Boolean(toValue(showImmediately))] as const,
    ([isActive, immediate]) => {
      clearTimer();

      if (!isActive) {
        visible.value = false;
        return;
      }

      if (immediate || visible.value || delayMs <= 0) {
        visible.value = true;
        return;
      }

      visible.value = false;
      timeoutId = window.setTimeout(() => {
        timeoutId = null;
        if (toValue(active)) visible.value = true;
      }, delayMs);
    },
    { immediate: true }
  );

  onScopeDispose(clearTimer);

  return readonly(visible);
}
