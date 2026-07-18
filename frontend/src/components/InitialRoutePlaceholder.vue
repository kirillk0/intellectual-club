<template>
  <div class="initial-route-placeholder">
    <div
      v-if="showRecoveryNotice"
      class="initial-route-placeholder__notice"
      role="status"
      aria-live="polite"
    >
      <span>{{ translate('Loading…') }}</span>
      <button type="button" @click="requestRecoveryNow">
        {{ translate('Retry now') }}
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useDelayedVisibility } from '@/features/app/delayedVisibility';
import { requestRecoveryNow } from '@/features/app/recoveryHeartbeat';
import { translate } from '@/i18n';

const showRecoveryNotice = useDelayedVisibility(true);
</script>

<style scoped>
.initial-route-placeholder {
  min-height: clamp(12rem, 42vh, 28rem);
  display: grid;
  place-content: center;
}

.initial-route-placeholder__notice {
  display: grid;
  justify-items: center;
  gap: 10px;
  color: var(--color-text-muted);
}
</style>
