<template>
  <ModalWindow
    :open="open"
    modal-class="attachment-preview-modal"
    :aria-label="title"
    @cancel="emit('close')"
  >
    <div class="attachment-preview-header">
      <div class="attachment-preview-title-wrap">
        <h3 class="attachment-preview-title">
          <button
            v-if="url"
            type="button"
            class="attachment-preview-title-link"
            :disabled="downloadPending"
            :aria-label="`Download ${title}`"
            :title="`Download ${title}`"
            @click="emit('download')"
          >
            {{ title }}
          </button>
          <span v-else>{{ title }}</span>
        </h3>
      </div>
      <div class="attachment-preview-actions">
        <button
          v-if="canNavigate"
          type="button"
          class="attachment-preview-action"
          aria-label="Previous attachment"
          title="Previous attachment"
          @click="emit('prev')"
        >
          <SvgIcon name="chevron-left" />
        </button>
        <button
          v-if="canNavigate"
          type="button"
          class="attachment-preview-action"
          aria-label="Next attachment"
          title="Next attachment"
          @click="emit('next')"
        >
          <SvgIcon name="chevron-right" />
        </button>
        <button
          type="button"
          class="attachment-preview-action attachment-preview-action--close"
          aria-label="Close preview"
          title="Close preview"
          @click="emit('close')"
        >
          <span aria-hidden="true">&#215;</span>
        </button>
      </div>
    </div>

    <div v-if="loading" class="muted attachment-preview-state">Loading attachment…</div>
    <div v-else-if="errorText" class="error-text attachment-preview-state">{{ errorText }}</div>
    <div v-else-if="kind === 'image'" class="attachment-preview-image-wrap">
      <img
        class="attachment-preview-image"
        :class="{ 'attachment-preview-image--interactive': canNavigate }"
        :src="url"
        :alt="title"
        @click="handleImageClick"
      />
    </div>
    <div v-else-if="kind === 'markdown'" class="attachment-preview-markdown">
      <div class="message assistant attachment-preview-message">
        <div class="bubble">
          <div class="message-content chat-markdown" v-html="markdownHtml"></div>
        </div>
      </div>
    </div>
    <pre v-else-if="kind === 'text'" class="attachment-preview-text">{{ textValue || '—' }}</pre>
    <div v-else class="attachment-preview-state muted">Preview is not available for this file type.</div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import ModalWindow from '@/components/ModalWindow.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { renderChatMessageHtml } from '@/utils/chatMarkdown';

interface Props {
  open: boolean;
  title: string;
  url?: string;
  kind: 'image' | 'text' | 'markdown' | 'binary';
  canNavigate?: boolean;
  loading?: boolean;
  downloadPending?: boolean;
  error?: string;
  text?: string;
}

const props = defineProps<Props>();
const emit = defineEmits<{
  (e: 'close'): void;
  (e: 'prev'): void;
  (e: 'next'): void;
  (e: 'download'): void;
}>();

const errorText = computed(() => (props.error || '').trim());
const textValue = computed(() => props.text ?? '');
const markdownHtml = computed(() => renderChatMessageHtml(textValue.value, { highlightCode: true }));

const handleImageClick = () => {
  if (props.kind !== 'image' || !props.canNavigate) return;
  emit('next');
};
</script>

<style scoped>
:global(.attachment-preview-modal) {
  width: min(980px, 96vw);
}

.attachment-preview-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 12px;
}

.attachment-preview-title-wrap {
  min-width: 0;
  flex: 1 1 auto;
}

.attachment-preview-title {
  margin: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.attachment-preview-title-link {
  color: inherit;
  display: block;
  max-width: 100%;
  overflow: hidden;
  padding: 0;
  border: 0;
  background: transparent;
  font: inherit;
  text-align: left;
  text-decoration: underline;
  text-underline-offset: 0.12em;
  text-overflow: ellipsis;
  white-space: nowrap;
  cursor: pointer;
}

.attachment-preview-title-link:hover:not(:disabled) {
  text-decoration-thickness: 2px;
}

.attachment-preview-title-link:disabled {
  cursor: progress;
  opacity: 0.7;
}

.attachment-preview-actions {
  display: flex;
  align-items: center;
  gap: 4px;
  flex: 0 0 auto;
}

.attachment-preview-action {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 36px;
  height: 36px;
  padding: 0;
  border: none;
  border-radius: 999px;
  background: transparent;
  color: #4b5563;
  cursor: pointer;
  transition:
    background-color 0.12s ease,
    color 0.12s ease;
}

.attachment-preview-action:hover {
  background: #f1f5f9;
  color: #111827;
}

.attachment-preview-action--close {
  font-size: 1.4rem;
  line-height: 1;
}

.attachment-preview-state {
  margin-top: 8px;
}

.attachment-preview-image-wrap {
  display: flex;
  align-items: center;
  justify-content: center;
  border: 1px solid #e5e7eb;
  border-radius: 12px;
  background: #f8fafc;
  min-height: 320px;
  max-height: 70vh;
  overflow: auto;
}

.attachment-preview-image {
  display: block;
  max-width: 100%;
  max-height: 70vh;
  object-fit: contain;
}

.attachment-preview-image--interactive {
  cursor: pointer;
}

.attachment-preview-text {
  margin: 0;
  white-space: pre-wrap;
  word-break: break-word;
  max-height: 70vh;
  overflow: auto;
  border: 1px solid #e5e7eb;
  border-radius: 12px;
  padding: 14px 16px;
  background: #f8fafc;
}

.attachment-preview-markdown {
  max-height: 70vh;
  overflow: auto;
  padding: 2px;
}

.attachment-preview-message {
  margin-bottom: 0;
}

.attachment-preview-message .bubble {
  margin-top: 0;
}
</style>
