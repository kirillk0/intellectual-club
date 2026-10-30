<template>
  <ModalWindow
    :open="open"
    :aria-label="t('Snooze chat')"
    max-width="460px"
    :cancel-disabled="saving"
    :submit-disabled="saving"
    submit-shortcut="auto"
    @cancel="close"
    @submit="confirm"
  >
    <h3 style="margin: 0">{{ t('Snooze chat') }}</h3>
    <div class="snooze-presets">
      <button type="button" :disabled="saving" @click="selectPreset('hour')">{{ t('In 1 hour') }}</button>
      <button type="button" :disabled="saving" @click="selectPreset('tomorrow')">{{ t('Tomorrow morning') }}</button>
    </div>
    <label class="stack">
      <span>{{ t('Choose date and time') }}</span>
      <input v-model="localDateTime" type="datetime-local" :disabled="saving" @input="validationError = ''" />
    </label>
    <p v-if="validationError || error" class="error-text" role="alert">{{ validationError || error }}</p>
    <div class="modal-actions">
      <div class="spacer"></div>
      <button type="button" :disabled="saving" @click="close">{{ t('Cancel') }}</button>
      <button type="button" class="primary" :disabled="saving" @click="confirm">{{ t(saving ? 'Saving…' : 'Snooze') }}</button>
    </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { ref, watch } from 'vue';
import ModalWindow from '@/components/ModalWindow.vue';
import { isFutureSnooze } from '@/features/chat/chatReadState';
import { translate as t } from '@/i18n';

const props = withDefaults(defineProps<{ open: boolean; saving?: boolean; error?: string }>(), {
  saving: false, error: '',
});
const emit = defineEmits<{
  confirm: [utcIso: string];
  'update:open': [open: boolean];
  cancel: [];
}>();
const localDateTime = ref('');
const validationError = ref('');

function selectPreset(preset: 'hour' | 'tomorrow') {
  const date = new Date();
  if (preset === 'hour') date.setTime(date.getTime() + 60 * 60 * 1000);
  else {
    date.setDate(date.getDate() + 1);
    date.setHours(9, 0, 0, 0);
  }
  const pad = (n: number) => String(n).padStart(2, '0');
  localDateTime.value = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
  validationError.value = '';
}
function close() {
  if (props.saving) return;
  emit('update:open', false);
  emit('cancel');
}
function confirm() {
  if (props.saving) return;
  if (!isFutureSnooze(localDateTime.value)) {
    validationError.value = t('Choose a future date and time.');
    return;
  }
  emit('confirm', new Date(localDateTime.value).toISOString());
}
watch(() => props.open, (open) => { if (open) selectPreset('hour'); }, { immediate: true });
</script>

<style scoped>
.snooze-presets { display: flex; flex-wrap: wrap; gap: 8px; }
</style>
