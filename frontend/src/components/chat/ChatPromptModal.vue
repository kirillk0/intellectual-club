<template>
  <ModalWindow :open="open" modal-class="prompt-modal" aria-label="Prompt" @cancel="emit('close')">
    <div class="prompt-modal__header">
      <h3 class="prompt-modal__title">Prompt</h3>
      <div class="prompt-modal__view-toggle" aria-label="Prompt view mode">
        <button
          type="button"
          :class="{ active: renderMarkdown }"
          :aria-pressed="renderMarkdown"
          @click="renderMarkdown = true"
        >
          Rendered
        </button>
        <button
          type="button"
          :class="{ active: !renderMarkdown }"
          :aria-pressed="!renderMarkdown"
          @click="renderMarkdown = false"
        >
          Text
        </button>
      </div>
    </div>
    <div v-if="loading" class="muted">Loading prompt…</div>
    <div v-else-if="errorText" class="error-text">{{ errorText }}</div>
    <div v-else-if="renderMarkdown" class="prompt-modal__markdown">
      <div v-if="promptText" class="message assistant prompt-modal__message">
        <div class="bubble">
          <div class="message-content chat-markdown" v-html="promptHtml"></div>
        </div>
      </div>
      <div v-else class="prompt-modal__empty muted">—</div>
    </div>
    <pre
      v-else
      class="code-block prompt-modal__text"
    >{{ promptText || '—' }}</pre>
    <div class="modal-actions">
      <div class="spacer"></div>
      <button type="button" @click="emit('close')">Close</button>
    </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';

import ModalWindow from '@/components/ModalWindow.vue';
import { renderChatMessageHtml } from '@/utils/chatMarkdown';

interface Props {
  open: boolean;
  loading?: boolean;
  error?: string;
  text?: string;
}

const props = defineProps<Props>();
const emit = defineEmits<{ (e: 'close'): void }>();

const renderMarkdown = ref(true);

const loading = computed(() => Boolean(props.loading));
const errorText = computed(() => (props.error || '').trim());
const promptText = computed(() => props.text ?? '');
const promptHtml = computed(() => renderChatMessageHtml(promptText.value, { highlightCode: true }));

watch(
  () => props.open,
  (open) => {
    if (open) renderMarkdown.value = true;
  },
);
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

.prompt-modal__view-toggle {
  display: inline-flex;
  align-items: center;
  border: 1px solid var(--color-border-strong);
  border-radius: 8px;
  overflow: hidden;
}

.prompt-modal__view-toggle button {
  min-width: 86px;
  border: 0;
  border-right: 1px solid var(--color-border-strong);
  border-radius: 0;
  background: var(--color-surface);
  color: var(--color-text);
}

.prompt-modal__view-toggle button:last-child {
  border-right: 0;
}

.prompt-modal__view-toggle button.active {
  background: var(--color-primary);
  color: var(--color-primary-contrast);
}

.prompt-modal__markdown {
  max-height: 60vh;
  overflow: auto;
  padding: 2px;
}

.prompt-modal__message {
  margin-bottom: 0;
}

.prompt-modal__message .bubble {
  margin-top: 0;
}

.prompt-modal__empty {
  padding: 10px 0;
}

.prompt-modal__text {
  max-height: 60vh;
  overflow: auto;
}
</style>
