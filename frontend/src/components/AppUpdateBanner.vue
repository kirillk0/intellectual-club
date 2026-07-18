<template>
  <section
    class="app-banner app-update-banner"
    role="status"
    aria-live="polite"
  >
    <div class="app-status-copy">
      <strong>{{ translate('A new version is available') }}</strong>
      <span>{{ translate('Reload when you are ready. Unsaved changes may need to be saved first.') }}</span>
    </div>
    <button
      type="button"
      class="primary"
      :disabled="updating"
      :aria-busy="updating"
      @click="emit('update')"
    >
      {{ translate(updating ? 'Updating…' : 'Update') }}
    </button>
  </section>
</template>

<script setup lang="ts">
import { translate } from '@/i18n';

defineProps<{
  updating: boolean;
}>();

const emit = defineEmits<{
  update: [];
}>();
</script>
