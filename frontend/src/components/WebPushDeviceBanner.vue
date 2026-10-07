<template>
  <section
    class="app-banner web-push-device-banner"
    role="status"
    aria-live="polite"
  >
    <div class="app-status-copy">
      <strong>{{ translate('Notifications on this device were turned off') }}</strong>
      <span v-if="notice === 'blocked'">
        {{ translate('Notification permission is blocked. Allow notifications for this app in the system or browser settings.') }}
      </span>
      <span v-else>
        {{ translate('The browser or the system removed the notification subscription for this device. Turn notifications on again to keep receiving alerts about finished generations.') }}
      </span>
      <span v-if="error" class="web-push-device-banner__error">{{ translate(error) }}</span>
    </div>
    <div class="web-push-device-banner__actions">
      <button
        v-if="notice === 'lost'"
        type="button"
        class="primary"
        :disabled="enabling"
        :aria-busy="enabling"
        @click="emit('enable')"
      >
        {{ translate(enabling ? 'Turning on…' : 'Turn on again') }}
      </button>
      <button type="button" :disabled="enabling" @click="emit('dismiss')">
        {{ translate('Dismiss') }}
      </button>
    </div>
  </section>
</template>

<script setup lang="ts">
import type { WebPushDeviceNotice } from '@/features/push/webPush';
import { translate } from '@/i18n';

defineProps<{
  notice: WebPushDeviceNotice;
  enabling: boolean;
  error: string;
}>();

const emit = defineEmits<{
  enable: [];
  dismiss: [];
}>();
</script>
