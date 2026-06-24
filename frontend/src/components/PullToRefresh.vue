<template>
  <div
    ref="rootRef"
    class="pull-to-refresh"
    :class="[
      `pull-to-refresh--${state}`,
      {
        'pull-to-refresh--active': visible,
        'pull-to-refresh--standalone': standalone,
      },
    ]"
    :style="rootStyle"
    @touchstart.passive="handleTouchStart"
    @touchmove="handleTouchMove"
    @touchend="handleTouchEnd"
    @touchcancel="handleTouchCancel"
    @click.capture="handleClickCapture"
  >
    <div class="pull-to-refresh__indicator" :aria-hidden="!visible">
      <div class="pull-to-refresh__status" role="status" aria-live="polite" :aria-label="label">
        <SvgIcon class="pull-to-refresh__icon" name="retry" size="16" />
        <span>{{ label }}</span>
      </div>
    </div>

    <div class="pull-to-refresh__content">
      <slot />
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, ref, type CSSProperties } from 'vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { useStackLayer } from '@/features/stack/useStackLayer';
import { translate } from '@/i18n';
import { isStandalonePwa } from '@/pwa';

type PullState = 'idle' | 'pulling' | 'ready' | 'refreshing';

const props = defineProps<{
  refresh: () => void | Promise<void>;
  disabled?: boolean;
}>();

const ACTIVATION_DISTANCE_PX = 6;
const TRIGGER_DISTANCE_PX = 86;
const TRIGGER_EXIT_DISTANCE_PX = 68;
const LINEAR_PULL_DISTANCE_PX = 104;
const LINEAR_PULL_RATIO = 0.82;
const ELASTIC_EXTRA_SCALE_PX = 54;
const ELASTIC_EXTRA_DISTANCE_PX = 120;
const REFRESHING_OFFSET_PX = 58;
const LOADED_STAY_TIME_MS = 360;
const CLICK_SUPPRESSION_MS = 450;

const rootRef = ref<HTMLElement | null>(null);
const state = ref<PullState>('idle');
const pullOffset = ref(0);
const pullProgress = ref(0);
const layer = useStackLayer();

let startX = 0;
let startY = 0;
let tracking = false;
let dragging = false;
let resetTimer: number | null = null;
let suppressClickUntil = 0;

const visible = computed(() => state.value !== 'idle' || pullOffset.value > 0);
const standalone = computed(() => isStandalonePwa());
const label = computed(() => {
  if (state.value === 'refreshing') return translate('Refreshing…');
  if (state.value === 'ready') return translate('Release to refresh');
  return translate('Pull to refresh');
});
const rootStyle = computed(
  () =>
    ({
      '--pull-to-refresh-offset': `${pullOffset.value}px`,
      '--pull-to-refresh-progress': pullProgress.value.toFixed(3),
      '--pull-to-refresh-icon-rotation': `${Math.round(pullProgress.value * 150)}deg`,
    }) as CSSProperties
);

function hasCoarsePointer() {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return false;
  return window.matchMedia('(hover: none), (pointer: coarse)').matches;
}

function pageScrollTop() {
  const scroller = document.scrollingElement || document.documentElement;
  return scroller?.scrollTop ?? window.scrollY ?? 0;
}

function isInteractiveTarget(target: EventTarget | null) {
  return target instanceof Element && Boolean(target.closest('input, textarea, select, [contenteditable="true"]'));
}

function clearResetTimer() {
  if (resetTimer == null) return;
  window.clearTimeout(resetTimer);
  resetTimer = null;
}

function resetPull() {
  clearResetTimer();
  pullOffset.value = 0;
  pullProgress.value = 0;
  state.value = 'idle';
}

function cancelTracking() {
  tracking = false;
  dragging = false;
  resetPull();
}

function rubberBandOffset(distance: number) {
  const raw = Math.max(0, distance - ACTIVATION_DISTANCE_PX);
  const linearOffset = LINEAR_PULL_DISTANCE_PX * LINEAR_PULL_RATIO;

  if (raw <= LINEAR_PULL_DISTANCE_PX) {
    return Math.round(raw * LINEAR_PULL_RATIO);
  }

  const extra = raw - LINEAR_PULL_DISTANCE_PX;
  const elasticOffset = ELASTIC_EXTRA_SCALE_PX * Math.log1p(extra / ELASTIC_EXTRA_DISTANCE_PX);
  return Math.round(linearOffset + elasticOffset);
}

function updatePullDistance(distance: number) {
  const raw = Math.max(0, distance - ACTIVATION_DISTANCE_PX);
  const nextOffset = rubberBandOffset(distance);
  pullOffset.value = nextOffset;
  pullProgress.value = Math.min(1, raw / TRIGGER_DISTANCE_PX);

  const readyDistance = state.value === 'ready' ? TRIGGER_EXIT_DISTANCE_PX : TRIGGER_DISTANCE_PX;
  state.value = raw >= readyDistance ? 'ready' : 'pulling';
}

function canStart(event: TouchEvent) {
  if (props.disabled || state.value === 'refreshing') return false;
  if (!isStandalonePwa() || !layer.active.value || !hasCoarsePointer()) return false;
  if (event.touches.length !== 1 || pageScrollTop() > 1) return false;
  if (isInteractiveTarget(event.target)) return false;
  return true;
}

function handleTouchStart(event: TouchEvent) {
  if (!canStart(event)) return;

  clearResetTimer();
  const touch = event.touches[0];
  startX = touch.clientX;
  startY = touch.clientY;
  tracking = true;
  dragging = false;
  pullOffset.value = 0;
  state.value = 'idle';
}

function handleTouchMove(event: TouchEvent) {
  if (!tracking || event.touches.length !== 1) return;
  if (props.disabled || !layer.active.value) {
    cancelTracking();
    return;
  }

  const touch = event.touches[0];
  const deltaX = touch.clientX - startX;
  const deltaY = touch.clientY - startY;

  if (!dragging) {
    if (deltaY <= 0 || pageScrollTop() > 1) {
      cancelTracking();
      return;
    }

    if (Math.abs(deltaX) > deltaY) {
      cancelTracking();
      return;
    }

    if (deltaY < ACTIVATION_DISTANCE_PX) return;
    dragging = true;
  }

  event.preventDefault();
  updatePullDistance(deltaY);
}

async function refreshNow() {
  if (state.value === 'refreshing') return;

  state.value = 'refreshing';
  pullOffset.value = REFRESHING_OFFSET_PX;
  pullProgress.value = 1;
  const startedAt = window.performance.now();

  try {
    await props.refresh();
  } catch (error) {
    console.warn('Pull-to-refresh failed.', error);
  } finally {
    const elapsed = window.performance.now() - startedAt;
    const delay = Math.max(0, LOADED_STAY_TIME_MS - elapsed);
    resetTimer = window.setTimeout(() => {
      resetTimer = null;
      resetPull();
    }, delay);
  }
}

function finishTouch() {
  if (!tracking) return;

  const shouldRefresh = dragging && state.value === 'ready';
  if (dragging) suppressClickUntil = Date.now() + CLICK_SUPPRESSION_MS;

  tracking = false;
  dragging = false;

  if (shouldRefresh) {
    void refreshNow();
    return;
  }

  resetPull();
}

function handleTouchEnd() {
  finishTouch();
}

function handleTouchCancel() {
  if (dragging) suppressClickUntil = Date.now() + CLICK_SUPPRESSION_MS;
  cancelTracking();
}

function handleClickCapture(event: MouseEvent) {
  if (Date.now() > suppressClickUntil) return;
  event.preventDefault();
  event.stopPropagation();
}

onBeforeUnmount(() => {
  clearResetTimer();
});
</script>

<style scoped>
.pull-to-refresh {
  --pull-to-refresh-offset: 0px;
  --pull-to-refresh-progress: 0;
  --pull-to-refresh-icon-rotation: 0deg;
  position: relative;
  min-width: 0;
}

@media (hover: none), (pointer: coarse) {
  .pull-to-refresh--standalone {
    min-height: 60vh;
  }
}

.pull-to-refresh__indicator {
  position: absolute;
  top: 0;
  right: 0;
  left: 0;
  z-index: 6;
  display: flex;
  justify-content: center;
  height: 48px;
  pointer-events: none;
  opacity: 0;
  transform: translate3d(0, calc(var(--pull-to-refresh-offset) - 52px), 0);
  transition:
    opacity 0.2s ease,
    transform 0.32s cubic-bezier(0.22, 0.61, 0.36, 1);
}

.pull-to-refresh--active .pull-to-refresh__indicator {
  opacity: 1;
}

.pull-to-refresh__status {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  height: 34px;
  max-width: calc(100vw - 32px);
  margin-top: 6px;
  padding: 0 12px;
  border: 1px solid var(--color-border-strong);
  border-radius: 999px;
  background: color-mix(in srgb, var(--color-surface-elevated) 94%, transparent);
  box-shadow: var(--shadow-menu);
  color: var(--color-text-muted);
  font-size: 0.9rem;
  line-height: 1;
  white-space: nowrap;
}

.pull-to-refresh__icon {
  color: var(--color-text-subtle);
  transform: rotate(var(--pull-to-refresh-icon-rotation));
  transition:
    color 0.18s ease,
    transform 0.22s cubic-bezier(0.22, 0.61, 0.36, 1);
}

.pull-to-refresh--ready .pull-to-refresh__icon {
  color: var(--color-primary);
  transform: rotate(180deg);
}

.pull-to-refresh--refreshing .pull-to-refresh__icon {
  animation: pull-to-refresh-spin 0.85s linear infinite;
  color: var(--color-primary);
}

.pull-to-refresh__content {
  display: flex;
  flex-direction: column;
  gap: 8px;
  min-width: 0;
  transform: translate3d(0, var(--pull-to-refresh-offset), 0);
  transition: transform 0.32s cubic-bezier(0.22, 0.61, 0.36, 1);
  will-change: transform;
}

.pull-to-refresh--pulling .pull-to-refresh__indicator,
.pull-to-refresh--pulling .pull-to-refresh__content,
.pull-to-refresh--ready .pull-to-refresh__indicator,
.pull-to-refresh--ready .pull-to-refresh__content {
  transition: none;
}

@keyframes pull-to-refresh-spin {
  to {
    transform: rotate(360deg);
  }
}
</style>
