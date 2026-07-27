<template>
  <ModalWindow
    :open="open"
    :modal-class="[
      'attachment-preview-modal',
      { 'attachment-preview-modal--fullscreen': fullscreen },
    ]"
    :backdrop-class="{ 'attachment-preview-backdrop--fullscreen': fullscreen }"
    :aria-label="title"
    :close-on-backdrop="!fullscreen"
    @cancel="handleCancel"
  >
    <div
      class="attachment-preview-header"
      :class="{ 'attachment-preview-header--fullscreen': fullscreen }"
    >
      <div v-if="!fullscreen" class="attachment-preview-title-wrap">
        <h3 class="attachment-preview-title">
          <button
            v-if="url"
            type="button"
            class="attachment-preview-title-link"
            :disabled="downloadPending"
            :aria-label="translate('Download {name}', { name: title })"
            :title="translate('Download {name}', { name: title })"
            @click="emit('download')"
          >
            {{ title }}
          </button>
          <span v-else>{{ title }}</span>
        </h3>
      </div>
      <div class="attachment-preview-actions">
        <button
          v-if="canNavigate && !fullscreen"
          type="button"
          class="attachment-preview-action"
          :aria-label="translate('Previous attachment')"
          :title="translate('Previous attachment')"
          @click="emit('prev')"
        >
          <SvgIcon name="chevron-left" />
        </button>
        <button
          v-if="canNavigate && !fullscreen"
          type="button"
          class="attachment-preview-action"
          :aria-label="translate('Next attachment')"
          :title="translate('Next attachment')"
          @click="emit('next')"
        >
          <SvgIcon name="chevron-right" />
        </button>
        <button
          v-if="!fullscreen"
          type="button"
          class="attachment-preview-action"
          :aria-label="translate('Open full-screen preview')"
          :title="translate('Open full-screen preview')"
          @click="fullscreen = true"
        >
          <SvgIcon name="maximize" />
        </button>
        <button
          v-if="fullscreen"
          type="button"
          class="attachment-preview-action attachment-preview-action--fullscreen-close"
          :aria-label="translate('Exit full-screen preview')"
          :title="translate('Exit full-screen preview')"
          @click="fullscreen = false"
        >
          <SvgIcon name="minimize" />
        </button>
        <button
          v-else
          type="button"
          class="attachment-preview-action attachment-preview-action--close"
          :aria-label="translate('Close preview')"
          :title="translate('Close preview')"
          @click="handleClose"
        >
          <SvgIcon name="x" />
        </button>
      </div>
    </div>

    <div
      class="attachment-preview-content"
      :class="{ 'attachment-preview-content--fullscreen': fullscreen }"
    >
      <div v-if="loading" class="muted attachment-preview-state">
        {{ translate('Loading attachment…') }}
      </div>
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
            <div ref="markdownEl" class="message-content chat-markdown" v-html="markdownHtml"></div>
          </div>
        </div>
      </div>
      <iframe
        v-else-if="kind === 'html'"
        :key="url || title"
        class="attachment-preview-html"
        :srcdoc="textValue"
        :title="title"
        sandbox="allow-scripts"
        allow="camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'"
        referrerpolicy="no-referrer"
      ></iframe>
      <pre v-else-if="kind === 'text'" class="attachment-preview-text">{{ textValue || '—' }}</pre>
      <div v-else class="attachment-preview-state muted">
        {{ translate('Preview is not available for this file type.') }}
      </div>
    </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { computed, nextTick, onMounted, onUpdated, ref } from 'vue';

import ModalWindow from '@/components/ModalWindow.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import type { AttachmentPreviewKind } from '@/features/chat/attachments';
import { translate } from '@/i18n';
import { enhanceRenderedChatMessageHtml, renderChatMessageHtml } from '@/utils/chatMarkdown';

interface Props {
  open: boolean;
  title: string;
  url?: string;
  kind: AttachmentPreviewKind;
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
const markdownEl = ref<HTMLElement | null>(null);
const fullscreen = ref(false);
let enhanceMarkdownToken = 0;

const scheduleEnhanceMarkdownHtml = () => {
  const token = ++enhanceMarkdownToken;

  void nextTick(async () => {
    const root = markdownEl.value;
    if (!root || token !== enhanceMarkdownToken) return;
    await enhanceRenderedChatMessageHtml(root, { highlightCode: true });
  });
};

onMounted(scheduleEnhanceMarkdownHtml);
onUpdated(scheduleEnhanceMarkdownHtml);

const handleImageClick = () => {
  if (props.kind !== 'image' || !props.canNavigate) return;
  emit('next');
};

const handleClose = () => {
  fullscreen.value = false;
  emit('close');
};

const handleCancel = () => {
  if (fullscreen.value) {
    fullscreen.value = false;
    return;
  }

  handleClose();
};
</script>

<style scoped>
:global(.attachment-preview-modal) {
  width: min(980px, 96vw);
}

:global(.modal-backdrop.attachment-preview-backdrop--fullscreen) {
  align-items: stretch;
  justify-content: stretch;
  padding: 0;
  background: var(--color-bg);
}

:global(.modal.attachment-preview-modal--fullscreen) {
  position: relative;
  width: 100%;
  height: 100dvh;
  max-height: none;
  padding: 0;
  border-radius: 0;
  box-shadow: none;
  overflow: hidden;
}

.attachment-preview-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 12px;
}

.attachment-preview-header--fullscreen {
  position: absolute;
  z-index: 2;
  top: calc(12px + var(--app-safe-area-top));
  right: calc(12px + var(--app-safe-area-right));
  margin: 0;
  pointer-events: none;
}

.attachment-preview-header--fullscreen .attachment-preview-actions {
  pointer-events: auto;
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
  color: var(--color-text-muted);
  cursor: pointer;
  transition:
    background-color 0.12s ease,
    color 0.12s ease;
}

.attachment-preview-action:hover {
  background: var(--color-surface-muted);
  color: var(--color-text);
}

.attachment-preview-action--close {
  font-size: 1.2rem;
}

.attachment-preview-action--fullscreen-close {
  border: 1px solid var(--color-border-strong);
  background: var(--color-surface);
  color: var(--color-text);
  box-shadow: var(--shadow-modal);
}

.attachment-preview-content {
  min-width: 0;
  min-height: 0;
}

.attachment-preview-content--fullscreen {
  width: 100%;
  height: 100%;
  overflow: hidden;
}

.attachment-preview-content--fullscreen > .attachment-preview-state {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  margin: 0;
  padding: 24px;
}

.attachment-preview-state {
  margin-top: 8px;
}

.attachment-preview-image-wrap {
  display: flex;
  align-items: center;
  justify-content: center;
  border: 1px solid var(--color-border-strong);
  border-radius: 12px;
  background: var(--color-surface-muted);
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

.attachment-preview-content--fullscreen .attachment-preview-image-wrap {
  width: 100%;
  height: 100%;
  min-height: 0;
  max-height: none;
  border: 0;
  border-radius: 0;
}

.attachment-preview-content--fullscreen .attachment-preview-image {
  max-height: 100%;
}

.attachment-preview-text {
  margin: 0;
  white-space: pre-wrap;
  word-break: break-word;
  max-height: 70vh;
  overflow: auto;
  border: 1px solid var(--color-border-strong);
  border-radius: 12px;
  padding: 14px 16px;
  background: var(--color-surface-muted);
}

.attachment-preview-content--fullscreen .attachment-preview-text {
  box-sizing: border-box;
  width: 100%;
  height: 100%;
  max-height: none;
  border: 0;
  border-radius: 0;
  padding:
    calc(20px + var(--app-safe-area-top))
    calc(20px + var(--app-safe-area-right))
    calc(20px + var(--app-safe-area-bottom))
    calc(20px + var(--app-safe-area-left));
}

.attachment-preview-html {
  display: block;
  width: 100%;
  height: min(70vh, 720px);
  min-height: min(320px, 70vh);
  border: 1px solid var(--color-border-strong);
  border-radius: 12px;
  background: #fff;
}

.attachment-preview-content--fullscreen .attachment-preview-html {
  height: 100%;
  min-height: 0;
  border: 0;
  border-radius: 0;
}

.attachment-preview-markdown {
  max-height: 70vh;
  overflow: auto;
  padding: 2px;
}

.attachment-preview-content--fullscreen .attachment-preview-markdown {
  box-sizing: border-box;
  height: 100%;
  max-height: none;
  padding:
    calc(20px + var(--app-safe-area-top))
    calc(20px + var(--app-safe-area-right))
    calc(20px + var(--app-safe-area-bottom))
    calc(20px + var(--app-safe-area-left));
}

.attachment-preview-message {
  margin-bottom: 0;
}

.attachment-preview-message .bubble {
  margin-top: 0;
}
</style>
