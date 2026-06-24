<template>
  <ModalWindow :open="open" modal-class="prompt-modal" aria-label="Prompt" @cancel="emit('close')">
    <div class="prompt-modal__header">
      <h3 class="prompt-modal__title">Prompt</h3>
    </div>
    <div v-if="loading" class="muted">Loading prompt…</div>
    <div v-else-if="errorText" class="error-text">{{ errorText }}</div>
    <MarkdownCodeViewer
      v-else-if="promptText"
      class="prompt-modal__text"
      :value="promptText"
      label="Prompt"
    />
    <div v-else class="prompt-modal__empty muted">—</div>
    <div class="modal-actions">
      <div class="spacer"></div>
      <button type="button" @click="emit('close')">Close</button>
    </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { computed, defineAsyncComponent, h } from 'vue';

import ModalWindow from '@/components/ModalWindow.vue';

const MarkdownCodeViewer = defineAsyncComponent({
  loader: () => import('@/components/MarkdownCodeViewer.vue'),
  loadingComponent: {
    setup: () => () => h('div', { class: 'muted prompt-modal__editor-loading', 'aria-live': 'polite' }, 'Loading editor…'),
  },
});

interface Props {
  open: boolean;
  loading?: boolean;
  error?: string;
  text?: string;
}

const props = defineProps<Props>();
const emit = defineEmits<{ (e: 'close'): void }>();

const loading = computed(() => Boolean(props.loading));
const errorText = computed(() => (props.error || '').trim());
const promptText = computed(() => props.text ?? '');
</script>

<style scoped>
:global(.prompt-modal) {
  max-width: 820px;
}

.prompt-modal__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
}

.prompt-modal__title {
  margin: 0;
}

.prompt-modal__empty {
  padding: 10px 0;
}

.prompt-modal__text {
  height: clamp(280px, calc(var(--app-vh, 1vh) * 60), 620px);
}
</style>
