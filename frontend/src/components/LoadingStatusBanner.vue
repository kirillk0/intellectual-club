<template>
  <section
    v-if="visible && status"
    class="app-banner loading-status-banner"
    role="status"
    aria-live="polite"
  >
    <div class="loading-status-banner__copy">
      <strong>{{ translate('Loading application') }}</strong>
      <span>{{ statusMessage }}</span>
    </div>

    <button type="button" @click="requestRecoveryNow">
      {{ translate('Retry now') }}
    </button>

    <div
      class="loading-status-progress"
      role="progressbar"
      :aria-label="translate('Application loading progress')"
      aria-valuemin="1"
      aria-valuemax="3"
      :aria-valuenow="activeStageIndex + 1"
      :aria-valuetext="translate(stageLabels[activeStageIndex])"
    >
      <div
        v-for="(stage, index) in stageLabels"
        :key="stage"
        class="loading-status-progress__stage"
        :class="{
          'loading-status-progress__stage--complete': index < activeStageIndex,
          'loading-status-progress__stage--active': index === activeStageIndex,
        }"
      >
        <span class="loading-status-progress__track" aria-hidden="true"></span>
        <span class="loading-status-progress__label">{{ translate(stage) }}</span>
      </div>
    </div>
  </section>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import { useLoadCoordinator, type LoadStage } from '@/features/app/loadCoordinator';
import { requestRecoveryNow } from '@/features/app/recoveryHeartbeat';
import { translate } from '@/i18n';

const stageLabels = ['Interface', 'Section', 'Data'] as const;
const stageIndexes: Record<Exclude<LoadStage, 'ready'>, number> = {
  runtime: 0,
  route: 1,
  data: 2,
};

const { status, visible } = useLoadCoordinator();

const activeStageIndex = computed(() => (status.value ? stageIndexes[status.value.stage] : 0));

const statusMessage = computed(() => {
  const current = status.value;
  if (!current) return '';
  if (current.waitingForConnection) return translate('Waiting for connection');
  if (current.waitingForVisibility) return translate('Loading paused while this tab is in the background');
  if (current.attempt > 1) {
    return translate('Retrying… Attempt {attempt}', { attempt: current.attempt });
  }
  return translate('Loading {stage}…', {
    stage: translate(stageLabels[activeStageIndex.value]).toLocaleLowerCase(),
  });
});
</script>

<style scoped>
.loading-status-banner {
  padding-block: 8px;
  border-bottom-color: var(--color-info-border);
  background: color-mix(in srgb, var(--color-info-bg) 88%, var(--color-surface));
  color: var(--color-info-text);
}

.loading-status-banner__copy {
  flex: 1 1 220px;
  min-width: 0;
  display: flex;
  align-items: baseline;
  gap: 8px;
}

.loading-status-banner__copy strong {
  flex: 0 0 auto;
}

.loading-status-banner__copy span {
  min-width: 0;
  color: var(--color-text-muted);
  font-size: 0.86rem;
}

.loading-status-progress {
  flex: 0 1 320px;
  min-width: min(240px, 100%);
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 6px;
}

.loading-status-progress__stage {
  display: grid;
  gap: 3px;
  color: var(--color-text-subtle);
  font-size: 0.72rem;
}

.loading-status-progress__track {
  height: 3px;
  border-radius: 999px;
  background: var(--color-border-strong);
  overflow: hidden;
}

.loading-status-progress__stage--complete .loading-status-progress__track,
.loading-status-progress__stage--active .loading-status-progress__track {
  background: var(--color-primary);
}

.loading-status-progress__stage--active {
  color: var(--color-text);
}

@media (prefers-reduced-motion: no-preference) {
  .loading-status-progress__stage--active .loading-status-progress__track {
    background-image: linear-gradient(
      90deg,
      transparent,
      color-mix(in srgb, var(--color-primary-contrast) 45%, transparent),
      transparent
    );
    background-size: 180% 100%;
    animation: loading-status-pulse 1.4s ease-in-out infinite;
  }
}

@keyframes loading-status-pulse {
  from {
    background-position: 180% 0;
  }

  to {
    background-position: -80% 0;
  }
}

@media (max-width: 640px) {
  .loading-status-banner {
    gap: 8px;
  }

  .loading-status-banner__copy {
    flex-basis: 100%;
    justify-content: space-between;
  }

  .loading-status-progress {
    flex-basis: 100%;
  }
}
</style>
