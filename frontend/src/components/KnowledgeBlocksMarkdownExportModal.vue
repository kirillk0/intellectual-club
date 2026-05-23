<template>
  <ModalWindow
    :open="open"
    backdrop-class="modal-backdrop--mobile-stretch"
    modal-class="markdown-transfer-modal markdown-export-modal"
    aria-label="Export knowledge blocks"
    :cancel-disabled="saving"
    :submit-disabled="saving || !selectedIds.length"
    submit-shortcut="auto"
    @cancel="close"
    @submit="confirm"
  >
        <div class="markdown-transfer-modal__header">
          <strong>Export knowledge blocks</strong>
          <button type="button" :disabled="saving" aria-label="Close" @click="close">Close</button>
        </div>

        <p v-if="error" class="error-text markdown-transfer-modal__message">{{ error }}</p>

        <div class="markdown-transfer-modal__bulk-actions">
          <span class="muted">{{ selectedIds.length }} of {{ blocks.length }} selected</span>
          <button type="button" :disabled="saving || !blocks.length" @click="selectAll">Select all</button>
          <button type="button" :disabled="saving || !selectedIds.length" @click="selectedIds = []">Clear</button>
        </div>

        <div class="list markdown-transfer-modal__list">
          <label v-for="block in blocks" :key="block.id" class="row markdown-transfer-modal__row">
            <input
              type="checkbox"
              :checked="selectedSet.has(block.id)"
              :disabled="saving"
              aria-label="Select block"
              @change="toggle(block.id)"
            />
            <div class="markdown-transfer-modal__row-main">
              <div class="markdown-transfer-modal__title">{{ block.name || `Block #${block.id}` }}</div>
              <div class="muted">{{ formatVersion(block.version) || 'No version' }}</div>
            </div>
            <span class="badge">{{ block.tokenCount }} tokens</span>
          </label>
        </div>

        <p v-if="!blocks.length" class="muted markdown-transfer-modal__message">No blocks in the current scope.</p>

        <div class="modal-actions">
          <button class="primary" type="button" :disabled="saving || !selectedIds.length" @click="confirm">
            {{ saving ? 'Exporting…' : 'Export' }}
          </button>
          <button type="button" :disabled="saving" @click="close">Cancel</button>
        </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import ModalWindow from '@/components/ModalWindow.vue';

type ExportBlock = {
  id: number;
  name: string;
  version: string;
  tokenCount: number;
};

const props = withDefaults(
  defineProps<{
    open: boolean;
    blocks: ExportBlock[];
    saving?: boolean;
    error?: string | null;
  }>(),
  {
    saving: false,
    error: null,
  }
);

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'export', ids: number[]): void;
}>();

const selectedIds = ref<number[]>([]);
const selectedSet = computed(() => new Set(selectedIds.value));

function formatVersion(value: string) {
  const text = String(value || '').trim();
  if (!text) return '';
  if (/^v\d+/i.test(text)) return text;
  if (/^\d+$/.test(text)) return `v${text}`;
  return text;
}

function selectAll() {
  selectedIds.value = props.blocks.map((block) => block.id);
}

function toggle(id: number) {
  const set = new Set(selectedIds.value);
  if (set.has(id)) set.delete(id);
  else set.add(id);
  selectedIds.value = props.blocks.map((block) => block.id).filter((blockId) => set.has(blockId));
}

function close() {
  if (props.saving) return;
  emit('update:open', false);
}

function confirm() {
  if (props.saving || !selectedIds.value.length) return;
  emit('export', selectedIds.value);
}

watch(
  () => [props.open, props.blocks.map((block) => block.id).join(',')],
  ([open]) => {
    if (open) selectAll();
  },
  { immediate: true }
);
</script>

<style scoped>
:global(.markdown-export-modal) {
  width: min(760px, 96vw);
  max-height: 90vh;
  display: flex;
  flex-direction: column;
  gap: 12px;
  overflow: hidden;
}

.markdown-transfer-modal__header,
.markdown-transfer-modal__bulk-actions,
.markdown-transfer-modal__row {
  display: flex;
  align-items: center;
  gap: 10px;
}

.markdown-transfer-modal__header {
  justify-content: space-between;
}

.markdown-transfer-modal__bulk-actions {
  justify-content: flex-end;
}

.markdown-transfer-modal__bulk-actions .muted {
  margin-right: auto;
}

.markdown-transfer-modal__list {
  min-height: 0;
  max-height: min(58vh, 520px);
  overflow: auto;
  overscroll-behavior: contain;
}

.markdown-transfer-modal__row {
  width: 100%;
}

.markdown-transfer-modal__row-main {
  flex: 1;
  min-width: 0;
}

.markdown-transfer-modal__title {
  font-weight: 600;
  overflow-wrap: anywhere;
}

.markdown-transfer-modal__message {
  margin: 0;
}

@media (max-width: 720px) {
  :global(.modal-backdrop--mobile-stretch) {
    padding: 0;
    align-items: stretch;
    justify-content: stretch;
  }

  :global(.markdown-export-modal) {
    width: 100%;
    height: calc(var(--app-vh, 1vh) * 100);
    max-height: calc(var(--app-vh, 1vh) * 100);
    border-radius: 0;
    padding-top: calc(12px + env(safe-area-inset-top));
    padding-right: 12px;
    padding-bottom: calc(12px + env(safe-area-inset-bottom));
    padding-left: 12px;
  }
}
</style>
