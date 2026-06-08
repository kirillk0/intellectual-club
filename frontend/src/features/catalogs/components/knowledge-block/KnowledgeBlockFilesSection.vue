<template>
  <div class="stack">
    <div class="knowledge-block-section-header">
      <div class="stack knowledge-block-section-title">
        <strong>Files</strong>
        <div class="muted knowledge-block-section-note">
          Only enabled files are visible to the model as file_id placeholders.
        </div>
      </div>
      <button type="button" :disabled="actionDisabled" @click="triggerFilesUpload">Attach files</button>
    </div>

    <input ref="filesInput" type="file" multiple class="knowledge-block-hidden-input" @change="handleFilesSelected" />

    <p v-if="loading" class="muted">Loading…</p>
    <p v-else-if="error" class="error-text">{{ error }}</p>

    <div v-else class="list">
      <div
        v-for="attachment in attachments"
        :key="attachment.id"
        class="row knowledge-block-file-row"
        :class="{
          'knowledge-block-file-row--disabled': attachment.enabled === false,
          'knowledge-block-file-row--pending': isPendingAttachment(attachment),
        }"
      >
        <label class="knowledge-block-file-row__enabled">
          <input
            type="checkbox"
            :checked="attachment.enabled !== false"
            :disabled="saving || sharedReadonly"
            aria-label="Enabled"
            title="Enabled"
            @change="toggleAttachmentEnabled(attachment, $event)"
          />
          <span>Enabled</span>
        </label>
        <div class="knowledge-block-file-row__main">
          <a
            v-if="!isPendingAttachment(attachment)"
            class="knowledge-block-file-row__name"
            :href="attachment.url"
            target="_blank"
            rel="noopener"
            title="Download file"
          >
            {{ attachment.filename }}
          </a>
          <span v-else class="knowledge-block-file-row__name">{{ attachment.filename }}</span>
          <div class="knowledge-block-file-row__meta">
            {{ attachment.mime_type || 'application/octet-stream' }} · {{ formatFileBytes(attachment.size_bytes) }}
            <span v-if="isPendingAttachment(attachment)"> · <span>Pending upload</span></span>
          </div>
          <div class="knowledge-block-file-row__id">
            <span class="muted">File ID</span>
            <code v-if="attachment.file_id">{{ attachment.file_id }}</code>
            <span v-else class="muted">Available after save</span>
          </div>
        </div>
        <button
          type="button"
          class="danger"
          :disabled="saving || sharedReadonly"
          @click="emit('remove-file', attachment)"
        >
          Remove
        </button>
      </div>

      <p v-if="!attachments.length" class="muted">No files attached.</p>
    </div>
    <div v-if="isNew" class="muted knowledge-block-section-note">Files will be uploaded when you save the block.</div>
    <div v-else-if="dirty" class="muted knowledge-block-section-note">
      File changes will be saved when you save the block.
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue';

import {
  isPendingKnowledgeBlockFile,
  type KnowledgeBlockFileDraftItem,
} from '@/features/catalogs/model/useKnowledgeBlockFileBindingsDraft';
import { formatFileBytes } from '@/utils/fileSize';

defineProps<{
  attachments: KnowledgeBlockFileDraftItem[];
  loading: boolean;
  error: string | null;
  dirty: boolean;
  saving: boolean;
  sharedReadonly: boolean;
  actionDisabled: boolean;
  isNew: boolean;
}>();

const emit = defineEmits<{
  (e: 'add-files', files: File[]): void;
  (e: 'remove-file', attachment: KnowledgeBlockFileDraftItem): void;
  (e: 'set-enabled', attachment: KnowledgeBlockFileDraftItem, enabled: boolean): void;
}>();

const filesInput = ref<HTMLInputElement | null>(null);
const isPendingAttachment = isPendingKnowledgeBlockFile;

function triggerFilesUpload() {
  filesInput.value?.click();
}

function handleFilesSelected(event: Event) {
  const target = event.target as HTMLInputElement | null;
  const files = Array.from(target?.files || []);
  if (target) target.value = '';
  if (!files.length) return;

  emit('add-files', files);
}

function toggleAttachmentEnabled(attachment: KnowledgeBlockFileDraftItem, event: Event) {
  const target = event.target as HTMLInputElement | null;
  if (!target) return;

  emit('set-enabled', attachment, Boolean(target.checked));
}
</script>

<style scoped>
.knowledge-block-section-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 10px;
}

.knowledge-block-section-title {
  gap: 2px;
}

.knowledge-block-section-note {
  font-size: 0.85rem;
}

.knowledge-block-hidden-input {
  display: none;
}

.knowledge-block-file-row {
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.knowledge-block-file-row--disabled .knowledge-block-file-row__main {
  opacity: 0.58;
}

.knowledge-block-file-row--pending {
  border-style: dashed;
  background: var(--color-info-bg);
}

.knowledge-block-file-row__enabled {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  margin: 0;
  font-size: 0.85rem;
  white-space: nowrap;
}

.knowledge-block-file-row__enabled input {
  width: 16px;
  height: 16px;
  margin: 0;
}

.knowledge-block-file-row__main {
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.knowledge-block-file-row__name {
  font-weight: 600;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.knowledge-block-file-row__meta {
  color: var(--color-text-muted);
  font-size: 0.85rem;
}

.knowledge-block-file-row__id {
  display: flex;
  align-items: baseline;
  gap: 6px;
  min-width: 0;
  font-size: 0.78rem;
}

.knowledge-block-file-row__id code {
  min-width: 0;
  overflow-wrap: anywhere;
  word-break: break-word;
}
</style>

