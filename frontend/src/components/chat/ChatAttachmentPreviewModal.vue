<template>
  <transition name="fade">
    <div v-if="open" class="modal-backdrop" @click.self="emit('close')">
      <div class="modal attachment-preview-modal" role="dialog" aria-modal="true" :aria-label="title">
        <div class="attachment-preview-header">
          <div class="attachment-preview-title-wrap">
            <h3 class="attachment-preview-title">
              <a
                v-if="url"
                class="attachment-preview-title-link"
                :href="url"
                :download="title"
              >
                {{ title }}
              </a>
              <span v-else>{{ title }}</span>
            </h3>
          </div>
        </div>

        <div v-if="loading" class="muted attachment-preview-state">Loading attachment…</div>
        <div v-else-if="errorText" class="error-text attachment-preview-state">{{ errorText }}</div>
        <div v-else-if="kind === 'image'" class="attachment-preview-image-wrap">
          <img class="attachment-preview-image" :src="url" :alt="title" />
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

        <div class="modal-actions">
          <div class="spacer"></div>
          <button type="button" @click="emit('close')">Close</button>
        </div>
      </div>
    </div>
  </transition>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import { renderChatMessageHtml } from '@/utils/chatMarkdown';

interface Props {
  open: boolean;
  title: string;
  url?: string;
  kind: 'image' | 'text' | 'markdown' | 'binary';
  loading?: boolean;
  error?: string;
  text?: string;
}

const props = defineProps<Props>();
const emit = defineEmits<{ (e: 'close'): void }>();

const errorText = computed(() => (props.error || '').trim());
const textValue = computed(() => props.text ?? '');
const markdownHtml = computed(() => renderChatMessageHtml(textValue.value, { highlightCode: true }));
</script>

<style scoped>
.attachment-preview-modal {
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
}

.attachment-preview-title {
  margin: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.attachment-preview-title-link {
  color: inherit;
  text-decoration: underline;
  text-underline-offset: 0.12em;
}

.attachment-preview-title-link:hover {
  text-decoration-thickness: 2px;
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
