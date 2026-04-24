<template>
  <transition name="fade">
    <div
      v-if="open"
      class="modal-backdrop"
      :class="{ 'modal-backdrop--compact': compactViewport }"
      @touchmove="handleBackdropTouchMove"
    >
      <div
        class="modal edit-message-modal"
        :class="{
          'edit-message-modal--dragging': dragActive,
          'edit-message-modal--compact': compactViewport,
        }"
        :style="modalStyle"
        role="dialog"
        aria-modal="true"
        :aria-label="title"
        @dragenter.prevent="handleDragEnter"
        @dragover.prevent="handleDragOver"
        @dragleave.prevent="handleDragLeave"
        @drop.prevent="handleDrop"
      >
        <h3 style="margin: 0">{{ title }}</h3>

        <div class="edit-message-modal__body">
          <div v-if="contents.length > 0" class="message-edit-content">
            <div class="message-edit-content__header">
              <div class="message-edit-label">
                {{ contents.length > 1 ? 'Content' : 'Message content' }}
              </div>
              <select
                v-if="contents.length > 1"
                v-model.number="selectedContentIndex"
                class="message-edit-select"
                aria-label="Select content"
              >
                <option v-for="idx in contents.length" :key="idx - 1" :value="idx - 1">
                  {{ `Content ${idx}` }}
                </option>
              </select>
            </div>

            <textarea
              class="message-edit-textarea"
              :value="selectedContentValue"
              rows="6"
              autofocus
              :aria-label="contents.length > 1 ? `Message content ${selectedContentIndex + 1}` : 'Message content'"
              @paste="handleTextareaPaste"
              @keydown.enter.ctrl.exact.prevent="handleTextareaSubmit"
              @keydown.enter.meta.exact.prevent="handleTextareaSubmit"
              @input="(event) => updateAt(selectedContentIndex, (event.target as HTMLTextAreaElement).value)"
            ></textarea>
          </div>

          <div v-else class="muted">No editable text content</div>

          <div v-if="showAttachments" class="message-attachments">
            <div class="message-attachments__header">
              <div class="message-edit-label">Attachments</div>
              <div class="attachment-actions">
                <button
                  class="attachment-actions__button"
                  type="button"
                  :disabled="!attachmentsEnabled"
                  :title="attachmentHelpText"
                  @click="openFilePicker"
                >
                  Attach files
                </button>
                <input
                  ref="fileInputRef"
                  class="hidden-file-input"
                  type="file"
                  multiple
                  :accept="attachmentAccept || undefined"
                  :disabled="!attachmentsEnabled"
                  @change="handleFilesSelected"
                />
              </div>
            </div>

            <div v-if="hasAttachments" class="attachment-list">
              <div
                v-for="attachment in existingAttachments"
                :key="`existing-${attachment.id}`"
                class="attachment-row"
                :title="`${attachment.name}  (${formatFileBytes(attachment.size)})`"
                role="button"
                tabindex="0"
                :aria-label="`Preview attachment ${attachment.name}`"
                @click="emit('preview-existing-attachment', attachment)"
                @keydown.enter.prevent="emit('preview-existing-attachment', attachment)"
                @keydown.space.prevent="emit('preview-existing-attachment', attachment)"
              >
                <span class="attachment-row__icon" aria-hidden="true"><SvgIcon :name="fileIconByMime(attachment.mimeType, attachment.name)" /></span>
                <span class="attachment-row__name">{{ attachment.name }}</span>
                <span class="attachment-row__size">{{ formatFileBytes(attachment.size) }}</span>
                <button
                  class="attachment-row__remove"
                  type="button"
                  aria-label="Remove attachment"
                  @click.stop="emit('remove-existing-attachment', attachment.id)"
                >✕</button>
              </div>

              <div
                v-for="item in pendingFiles"
                :key="`pending-${item.id}`"
                class="attachment-row"
                :title="`${item.name}  (${formatFileBytes(item.size)})`"
                role="button"
                tabindex="0"
                :aria-label="`Preview attachment ${item.name}`"
                @click="emit('preview-pending-file', item.id)"
                @keydown.enter.prevent="emit('preview-pending-file', item.id)"
                @keydown.space.prevent="emit('preview-pending-file', item.id)"
              >
                <span class="attachment-row__icon" aria-hidden="true"><SvgIcon :name="fileIconByMime(item.mimeType, item.name)" /></span>
                <div class="attachment-row__meta">
                  <span class="attachment-row__name">{{ item.name }}</span>
                  <span class="attachment-row__status">{{ describePendingFileStatus(item) }}</span>
                  <div
                    v-if="item.uploadStatus !== 'idle' || item.progress > 0"
                    class="attachment-row__progress"
                    aria-hidden="true"
                  >
                    <span class="attachment-row__progress-bar" :style="{ width: `${pendingFileProgress(item)}%` }"></span>
                  </div>
                </div>
                <button
                  class="attachment-row__remove"
                  type="button"
                  aria-label="Remove pending attachment"
                  @click.stop="emit('remove-pending-file', item.id)"
                >✕</button>
              </div>
            </div>

            <div v-else class="muted">No attachments</div>
          </div>
        </div>

        <div v-if="dragActive && showAttachments && attachmentsEnabled" class="drop-hint">
          {{ attachmentDropHint }}
        </div>

        <div class="modal-actions">
          <span v-if="errorText" class="error-text">{{ errorText }}</span>
          <div class="spacer"></div>
          <button type="button" @click="emit('cancel')" :disabled="saving">Cancel</button>
          <button class="primary" type="button" @click="emit('save')" :disabled="saving">
            {{ confirmLabel }}
          </button>
        </div>
      </div>
    </div>
  </transition>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue';

import {
  clipboardHasStringContent,
  describePendingFileUploadStatus,
  extractClipboardImageFiles,
  fileIconByMime,
  formatFileBytes,
  pendingFileProgressPercent,
  type ExistingChatAttachment,
  type PendingChatFile,
} from '@/features/chat/attachments';
import SvgIcon from '@/components/icons/SvgIcon.vue';

interface Props {
  open: boolean;
  mode: 'edit' | 'branch';
  modelValue: string[];
  existingAttachments?: ExistingChatAttachment[];
  pendingFiles?: PendingChatFile[];
  error?: string;
  saving?: boolean;
  saveLabel?: string;
  attachmentsEnabled?: boolean;
  attachmentAccept?: string;
  attachmentHelp?: string;
}

const props = withDefaults(defineProps<Props>(), {
  existingAttachments: () => [],
  pendingFiles: () => [],
  attachmentsEnabled: true,
  attachmentAccept: '',
  attachmentHelp: '',
});

const emit = defineEmits<{
  (e: 'update:modelValue', value: string[]): void;
  (e: 'cancel'): void;
  (e: 'save'): void;
  (e: 'add-files', files: File[]): void;
  (e: 'remove-pending-file', id: string): void;
  (e: 'remove-existing-attachment', id: number): void;
  (e: 'preview-existing-attachment', attachment: ExistingChatAttachment): void;
  (e: 'preview-pending-file', id: string): void;
}>();

const fileInputRef = ref<HTMLInputElement | null>(null);
const dragActive = ref(false);
const dragDepth = ref(0);
const selectedContentIndex = ref(0);
const modalHeightPx = ref(0);
const previousBodyOverflow = ref<string | null>(null);
const previousHtmlOverflow = ref<string | null>(null);
const lockedScrollX = ref(0);
const lockedScrollY = ref(0);

const contents = computed(() => (Array.isArray(props.modelValue) ? props.modelValue : []));
const existingAttachments = computed(() => props.existingAttachments || []);
const pendingFiles = computed(() => props.pendingFiles || []);
const selectedContentValue = computed(() => contents.value[selectedContentIndex.value] ?? '');
const modalStyle = computed(() =>
  modalHeightPx.value > 0 ? { '--edit-message-modal-height': `${modalHeightPx.value}px` } : {}
);
const compactViewport = computed(() => modalHeightPx.value > 0 && modalHeightPx.value < 620);
let viewportSyncTimeouts: number[] = [];

watch(
  () => props.open,
  (open, wasOpen) => {
    if (open && !wasOpen) {
      selectedContentIndex.value = Math.max(contents.value.length - 1, 0);
    }
    if (!open) {
      selectedContentIndex.value = 0;
      dragDepth.value = 0;
      dragActive.value = false;
    }
  },
  { immediate: true }
);

watch(
  () => contents.value.length,
  (length) => {
    if (length <= 0) {
      selectedContentIndex.value = 0;
      return;
    }

    if (selectedContentIndex.value >= length) {
      selectedContentIndex.value = length - 1;
    }
  },
  { immediate: true }
);

const updateAt = (idx: number, value: string) => {
  const next = [...contents.value];
  next[idx] = value;
  emit('update:modelValue', next);
};

const saving = computed(() => Boolean(props.saving));
const errorText = computed(() => (props.error || '').trim());
const showAttachments = computed(() => props.mode === 'edit' || props.mode === 'branch');
const attachmentsEnabled = computed(() => Boolean(props.attachmentsEnabled));
const hasAttachments = computed(
  () => existingAttachments.value.length > 0 || pendingFiles.value.length > 0
);
const attachmentAccept = computed(() => (props.attachmentAccept || '').trim());
const attachmentHelpText = computed(() => (props.attachmentHelp || '').trim());
const attachmentDropHint = computed(() =>
  attachmentAccept.value === 'image/*' ? 'Drop images to attach' : 'Drop files to attach'
);
const title = computed(() => (props.mode === 'branch' ? 'Branch message' : 'Edit message'));
const confirmLabel = computed(() => {
  if ((props.saveLabel || '').trim() !== '') return props.saveLabel || '';
  if (saving.value) return props.mode === 'branch' ? 'Branching…' : 'Saving…';
  return props.mode === 'branch' ? 'Branch' : 'Save';
});
const describePendingFileStatus = describePendingFileUploadStatus;
const pendingFileProgress = pendingFileProgressPercent;

const handleTextareaSubmit = () => {
  if (saving.value) return;
  emit('save');
};

const handleWindowKeydown = (event: KeyboardEvent) => {
  if (!props.open || saving.value) return;
  if (event.key !== 'Escape') return;
  emit('cancel');
};

const computeModalHeight = () => {
  const visualViewport = window.visualViewport;
  const viewportHeight = visualViewport?.height ?? window.innerHeight;
  const isNarrowViewport = window.matchMedia('(max-width: 640px)').matches;
  const viewportInset = isNarrowViewport ? 20 : 40;
  modalHeightPx.value = Math.max(320, Math.round(viewportHeight - viewportInset));
};

const clearViewportSyncTimeouts = () => {
  for (const timeoutId of viewportSyncTimeouts) {
    window.clearTimeout(timeoutId);
  }
  viewportSyncTimeouts = [];
};

const syncViewport = () => {
  computeModalHeight();
  enforceWindowScrollLock();
};

const scheduleModalHeightRecalc = () => {
  clearViewportSyncTimeouts();
  window.requestAnimationFrame(() => {
    window.requestAnimationFrame(() => {
      syncViewport();
    });
  });

  viewportSyncTimeouts = [80, 180, 320].map((delay) =>
    window.setTimeout(() => {
      syncViewport();
    }, delay)
  );
};

const lockDocumentScroll = () => {
  if (previousBodyOverflow.value === null) {
    previousBodyOverflow.value = document.body.style.overflow;
  }
  if (previousHtmlOverflow.value === null) {
    previousHtmlOverflow.value = document.documentElement.style.overflow;
  }

  lockedScrollX.value = window.scrollX;
  lockedScrollY.value = window.scrollY;

  document.body.style.overflow = 'hidden';
  document.documentElement.style.overflow = 'hidden';
};

const unlockDocumentScroll = () => {
  document.body.style.overflow = previousBodyOverflow.value ?? '';
  document.documentElement.style.overflow = previousHtmlOverflow.value ?? '';

  previousBodyOverflow.value = null;
  previousHtmlOverflow.value = null;
  window.scrollTo(lockedScrollX.value, lockedScrollY.value);
};

const attachViewportListeners = () => {
  window.addEventListener('resize', scheduleModalHeightRecalc);
  window.addEventListener('orientationchange', scheduleModalHeightRecalc);
  window.visualViewport?.addEventListener('resize', scheduleModalHeightRecalc);
  window.visualViewport?.addEventListener('scroll', scheduleModalHeightRecalc);
};

const detachViewportListeners = () => {
  window.removeEventListener('resize', scheduleModalHeightRecalc);
  window.removeEventListener('orientationchange', scheduleModalHeightRecalc);
  window.visualViewport?.removeEventListener('resize', scheduleModalHeightRecalc);
  window.visualViewport?.removeEventListener('scroll', scheduleModalHeightRecalc);
};

const enforceWindowScrollLock = () => {
  if (!props.open) return;

  if (window.scrollX !== lockedScrollX.value || window.scrollY !== lockedScrollY.value) {
    window.scrollTo(lockedScrollX.value, lockedScrollY.value);
  }
};

const handleDocumentFocusChange = () => {
  if (!props.open) return;
  scheduleModalHeightRecalc();
};

const attachScrollLockListeners = () => {
  window.addEventListener('scroll', enforceWindowScrollLock, { passive: true });
  document.addEventListener('scroll', enforceWindowScrollLock, { passive: true, capture: true });
  document.addEventListener('focusin', handleDocumentFocusChange);
  document.addEventListener('focusout', handleDocumentFocusChange);
  document.addEventListener('touchmove', handleBackdropTouchMove, { passive: false, capture: true });
};

const detachScrollLockListeners = () => {
  window.removeEventListener('scroll', enforceWindowScrollLock);
  document.removeEventListener('scroll', enforceWindowScrollLock, true);
  document.removeEventListener('focusin', handleDocumentFocusChange);
  document.removeEventListener('focusout', handleDocumentFocusChange);
  document.removeEventListener('touchmove', handleBackdropTouchMove, true);
  clearViewportSyncTimeouts();
};

const handleBackdropTouchMove = (event: TouchEvent) => {
  const target = event.target as HTMLElement | null;
  if (!target) {
    if (event.cancelable) event.preventDefault();
    return;
  }

  if (target.closest('.message-edit-textarea, .attachment-list')) {
    return;
  }

  if (event.cancelable) {
    event.preventDefault();
  }
};

watch(
  () => props.open,
  (open) => {
    if (open) {
      window.addEventListener('keydown', handleWindowKeydown);
      lockDocumentScroll();
      attachViewportListeners();
      attachScrollLockListeners();
      scheduleModalHeightRecalc();
      return;
    }

    window.removeEventListener('keydown', handleWindowKeydown);
    detachViewportListeners();
    detachScrollLockListeners();
    unlockDocumentScroll();
  },
  { immediate: true }
);

onBeforeUnmount(() => {
  window.removeEventListener('keydown', handleWindowKeydown);
  detachViewportListeners();
  detachScrollLockListeners();
  unlockDocumentScroll();
});

const openFilePicker = () => {
  if (!attachmentsEnabled.value) return;
  fileInputRef.value?.click();
};

const handleFilesSelected = (event: Event) => {
  if (!attachmentsEnabled.value) return;
  const input = event.target as HTMLInputElement | null;
  const files = Array.from(input?.files || []);
  if (files.length) emit('add-files', files);
  if (input) input.value = '';
};

const handleTextareaPaste = (event: ClipboardEvent) => {
  if (!showAttachments.value || !attachmentsEnabled.value) return;

  const files = extractClipboardImageFiles(event);
  if (!files.length) return;

  emit('add-files', files);

  if (!clipboardHasStringContent(event)) {
    event.preventDefault();
  }
};

const dragEventHasFiles = (event: DragEvent) => {
  const types = Array.from(event.dataTransfer?.types || []);
  return types.includes('Files');
};

const handleDragEnter = (event: DragEvent) => {
  if (!showAttachments.value || !attachmentsEnabled.value) return;
  if (!dragEventHasFiles(event)) return;

  dragDepth.value += 1;
  dragActive.value = true;
};

const handleDragOver = (event: DragEvent) => {
  if (!showAttachments.value || !attachmentsEnabled.value) return;
  if (!dragEventHasFiles(event)) return;

  dragActive.value = true;
};

const handleDragLeave = (event: DragEvent) => {
  if (!showAttachments.value || !attachmentsEnabled.value) return;
  if (!dragEventHasFiles(event)) return;

  const currentTarget = event.currentTarget as HTMLElement | null;
  const relatedTarget = event.relatedTarget as Node | null;
  if (currentTarget && relatedTarget && currentTarget.contains(relatedTarget)) return;

  dragDepth.value = Math.max(0, dragDepth.value - 1);
  if (dragDepth.value === 0) {
    dragActive.value = false;
  }
};

const handleDrop = (event: DragEvent) => {
  if (!showAttachments.value || !attachmentsEnabled.value) return;
  if (!dragEventHasFiles(event)) return;

  dragDepth.value = 0;
  dragActive.value = false;
  const files = Array.from(event.dataTransfer?.files || []);
  if (files.length) emit('add-files', files);
};
</script>

<style scoped>
.edit-message-modal {
  display: grid;
  gap: 12px;
  width: min(920px, 96vw);
  height: var(--edit-message-modal-height, calc(100dvh - 40px));
  max-height: var(--edit-message-modal-height, calc(100dvh - 40px));
  padding: 16px 18px;
  overflow: hidden;
  grid-template-rows: auto minmax(0, 1fr) auto;
  border: 1px solid transparent;
  transition:
    border-color 0.18s ease,
    background-color 0.18s ease;
  overscroll-behavior: contain;
}

.edit-message-modal--compact {
  height: auto;
  overflow: auto;
  align-content: start;
}

.edit-message-modal--dragging {
  border-color: #2563eb;
  background: rgba(219, 234, 254, 0.24);
}

.edit-message-modal__body {
  display: grid;
  gap: 10px;
  min-height: 0;
  grid-template-rows: minmax(0, 1fr) auto;
  overflow: hidden;
}

.edit-message-modal--compact .edit-message-modal__body {
  overflow: visible;
  grid-template-rows: auto auto;
}

.message-edit-content {
  display: grid;
  gap: 8px;
  min-height: 0;
  grid-template-rows: auto minmax(0, 1fr);
  overflow: visible;
}

.edit-message-modal--compact .message-edit-content {
  min-height: min(220px, 42vh);
}

.message-edit-content__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.message-edit-select {
  width: auto;
  min-width: 136px;
  max-width: 220px;
}

.message-edit-label {
  font-size: 0.78rem;
  color: #6b7280;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}

.message-edit-textarea {
  min-height: 0 !important;
  height: 100% !important;
  max-height: none !important;
  resize: none;
  width: 100%;
  align-self: stretch;
  overscroll-behavior: contain;
  touch-action: pan-y;
}

.edit-message-modal--compact .message-edit-textarea {
  min-height: min(180px, 34vh) !important;
}

.message-attachments {
  display: grid;
  gap: 8px;
  min-height: 0;
}

.edit-message-modal--compact .message-attachments {
  gap: 6px;
}

.message-attachments__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.message-attachments__header .message-edit-label {
  margin: 0;
}

.attachment-list {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
  gap: 4px 8px;
  max-height: min(220px, 24vh);
  overflow-y: auto;
  padding-right: 4px;
  overscroll-behavior: contain;
  touch-action: pan-y;
}

.edit-message-modal--compact .attachment-list {
  max-height: min(112px, 18vh);
}

.attachment-row {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 4px 7px;
  border-radius: 6px;
  min-width: 0;
  border: 1px solid rgba(15, 23, 42, 0.08);
  background: rgba(248, 250, 252, 0.9);
  cursor: pointer;
  outline: none;
  transition: background-color 0.12s ease;
}

.attachment-row:hover {
  background: rgba(241, 245, 249, 1);
}

.attachment-row:focus-visible {
  background: rgba(219, 234, 254, 0.55);
  box-shadow: inset 0 0 0 1px rgba(37, 99, 235, 0.35);
}

.attachment-row__icon {
  flex: 0 0 auto;
  font-size: 0.9rem;
  line-height: 1;
}

.attachment-row__name {
  font-size: 0.82rem;
  font-weight: 500;
  line-height: 1.2;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: #1a1a1a;
}

.attachment-row__meta {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.attachment-row__size {
  flex: 0 0 auto;
  font-size: 0.72rem;
  color: #888;
  white-space: nowrap;
}

.attachment-row__status {
  font-size: 0.72rem;
  color: #667085;
  line-height: 1.25;
}

.attachment-row__progress {
  position: relative;
  width: 100%;
  height: 5px;
  border-radius: 999px;
  background: rgba(148, 163, 184, 0.28);
  overflow: hidden;
}

.attachment-row__progress-bar {
  position: absolute;
  inset: 0 auto 0 0;
  width: 0;
  border-radius: inherit;
  background: linear-gradient(90deg, #0f766e, #22c55e);
}

.attachment-row__remove {
  flex: 0 0 auto;
  width: 20px;
  height: 20px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  border: none;
  border-radius: 4px;
  background: transparent;
  color: #999;
  font-size: 0.75rem;
  cursor: pointer;
  transition: background-color 0.12s ease, color 0.12s ease;
}

.attachment-row__remove:hover {
  background: rgba(0, 0, 0, 0.08);
  color: #c0392b;
}

.attachment-actions {
  display: flex;
  justify-content: flex-start;
}

.attachment-actions__button {
  padding: 4px 10px;
  min-height: 28px;
  font-size: 0.82rem;
}

.hidden-file-input {
  display: none;
}

.drop-hint {
  font-size: 0.86rem;
  color: #1d4ed8;
  pointer-events: none;
}

.modal-backdrop {
  overscroll-behavior: none;
  overflow: hidden;
}

.modal-backdrop--compact {
  align-items: flex-start;
  padding-top: 8px;
  padding-bottom: 8px;
}

.edit-message-modal--compact .modal-actions {
  position: sticky;
  bottom: 0;
  background: #fff;
  padding-top: 8px;
}

@media (max-width: 640px) {
  .modal-backdrop {
    align-items: flex-start;
    padding: 10px 4px;
  }

  .edit-message-modal {
    width: min(100vw - 8px, 920px);
    height: var(--edit-message-modal-height, calc(100dvh - 20px));
    max-height: var(--edit-message-modal-height, calc(100dvh - 20px));
    padding: 12px;
    border-radius: 10px;
  }

  .message-edit-content__header {
    align-items: stretch;
    flex-direction: column;
    gap: 6px;
  }

  .message-edit-select {
    max-width: none;
    width: 100%;
  }

  .message-attachments__header {
    align-items: center;
  }

  .attachment-list {
    grid-template-columns: 1fr;
  }
}
</style>
