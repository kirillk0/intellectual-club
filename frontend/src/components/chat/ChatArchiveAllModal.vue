<template>
  <ModalWindow :open="true" :aria-label="t('Archive all')" :cancel-disabled="saving" :submit-disabled="loading || saving || !preview?.count" max-width="480px" @cancel="emit('close')" @submit="confirm">
    <div class="stack">
      <h3>{{ t('Archive all') }}</h3>
      <p>{{ t('Bot filter: {bot}', { bot: botLabel }) }}</p>
      <p v-if="loading">{{ t('Loading…') }}</p>
      <p v-else-if="preview">{{ t('Archive {count} chats from Other chats?', { count: preview.count }) }}</p>
      <p class="muted">{{ t('Chats with drafts or active reminders, including subchats, will be skipped. All pages are included.') }}</p>
      <p v-if="error" class="error-text" role="alert">{{ error }}</p>
      <div class="toolbar">
        <button type="button" :disabled="saving" @click="emit('close')">{{ t('Cancel') }}</button>
        <button v-if="!loading && !preview" type="button" @click="loadPreview">{{ t('Retry') }}</button>
        <button class="primary" type="button" :disabled="loading || saving || !preview?.count" @click="confirm">{{ t(saving ? 'Archiving…' : 'Archive all') }}</button>
      </div>
    </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { onMounted, ref } from 'vue';
import ModalWindow from '@/components/ModalWindow.vue';
import { api } from '@/api/client';
import { translate as t } from '@/i18n';
import { isChatReadStateConflict } from '@/features/chat/chatReadState';

const props = defineProps<{ bot: string; botLabel: string }>();
const emit = defineEmits<{ close: []; archived: [count: number] }>();
const preview = ref<{ count: number; revision: string } | null>(null);
const loading = ref(false);
const saving = ref(false);
const error = ref('');

async function loadPreview() {
  loading.value = true;
  preview.value = null;
  try {
    const params = new URLSearchParams();
    if (props.bot) params.set('bot', props.bot);
    preview.value = await api.get(`/api/bff/chat-list/archive-other-preview?${params}`, { retry: false, showErrorBanner: false });
  } catch {
    error.value = t('Failed to prepare archive. Please try again.');
  } finally {
    loading.value = false;
  }
}

async function confirm() {
  if (saving.value || loading.value || !preview.value?.count) return;
  saving.value = true;
  error.value = '';
  try {
    const result = await api.post<{ count: number }>('/api/bff/chat-list/archive-other', {
      bot: props.bot, expected_revision: preview.value.revision,
    }, { retry: false, showErrorBanner: false });
    emit('archived', result.count);
  } catch (cause) {
    if (isChatReadStateConflict(cause)) {
      error.value = t('The chat list changed. Review the updated count and confirm again.');
      await loadPreview();
    } else {
      error.value = t('Failed to archive chats. Please try again.');
    }
  } finally {
    saving.value = false;
  }
}

onMounted(loadPreview);
</script>
