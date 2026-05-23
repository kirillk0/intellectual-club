<template>
  <ModalWindow
    :open="open"
    backdrop-class="modal-backdrop--mobile-stretch"
    modal-class="markdown-transfer-modal markdown-import-modal"
    aria-label="Import knowledge blocks"
    :cancel-disabled="saving"
    :submit-disabled="saving || !items.length"
    submit-shortcut="auto"
    @cancel="close"
    @submit="confirm"
  >
        <div class="markdown-transfer-modal__header">
          <strong>Import knowledge blocks</strong>
          <button type="button" :disabled="saving" aria-label="Close" @click="close">Close</button>
        </div>

        <label class="markdown-transfer-modal__version">
          Version
          <input
            v-model="version"
            type="text"
            class="full"
            placeholder="Leave unchanged"
            :disabled="saving"
          />
        </label>

        <p v-if="error" class="error-text markdown-transfer-modal__message">{{ error }}</p>

        <div class="list markdown-transfer-modal__list">
          <section v-for="item in items" :key="item.key" class="row markdown-transfer-modal__row">
            <div class="markdown-transfer-modal__row-main">
              <div class="markdown-transfer-modal__title">{{ item.name }}</div>
              <div class="muted markdown-transfer-modal__meta">
                <span>{{ item.filename }}</span>
                <span aria-hidden="true">·</span>
                <span>{{ item.external_id || 'New external ID' }}</span>
              </div>
              <div v-if="item.existing_block" class="muted markdown-transfer-modal__meta">
                <span>Matches {{ item.existing_block.name }}</span>
                <span v-if="item.existing_block.version" aria-hidden="true">·</span>
                <span v-if="item.existing_block.version">{{ item.existing_block.version }}</span>
              </div>
            </div>

            <select
              class="markdown-transfer-modal__action"
              :value="decisionFor(item)"
              :disabled="saving"
              aria-label="Import action"
              @change="handleDecisionChange(item.key, $event)"
            >
              <option v-for="action in item.available_actions" :key="action" :value="action">
                {{ actionLabel(action) }}
              </option>
            </select>
          </section>
        </div>

        <p v-if="!items.length" class="muted markdown-transfer-modal__message">No Markdown files found.</p>

        <div class="modal-actions">
          <button class="primary" type="button" :disabled="saving || !items.length" @click="confirm">
            {{ saving ? 'Importing…' : 'Import' }}
          </button>
          <button type="button" :disabled="saving" @click="close">Cancel</button>
        </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { ref, watch } from 'vue';
import type { MarkdownImportAction, MarkdownImportItem } from '@/api/knowledgeBlocksMarkdown';
import ModalWindow from '@/components/ModalWindow.vue';

const props = withDefaults(
  defineProps<{
    open: boolean;
    items: MarkdownImportItem[];
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
  (e: 'import', payload: { version: string; decisions: Record<string, MarkdownImportAction> }): void;
}>();

const version = ref('');
const decisions = ref<Record<string, MarkdownImportAction>>({});

function actionLabel(action: MarkdownImportAction) {
  switch (action) {
    case 'import':
      return 'Import';
    case 'update':
      return 'Update';
    case 'create_new':
      return 'Create new';
    case 'skip':
      return 'Skip';
    default:
      return action;
  }
}

function decisionFor(item: MarkdownImportItem) {
  return decisions.value[item.key] || item.default_action;
}

function setDecision(key: string, value: string) {
  decisions.value = {
    ...decisions.value,
    [key]: value as MarkdownImportAction,
  };
}

function handleDecisionChange(key: string, event: Event) {
  const target = event.target instanceof HTMLSelectElement ? event.target : null;
  if (!target) return;
  setDecision(key, target.value);
}

function reset() {
  version.value = '';
  decisions.value = Object.fromEntries(props.items.map((item) => [item.key, item.default_action]));
}

function close() {
  if (props.saving) return;
  emit('update:open', false);
}

function confirm() {
  if (props.saving || !props.items.length) return;
  emit('import', { version: version.value, decisions: decisions.value });
}

watch(
  () => [props.open, props.items.map((item) => `${item.key}:${item.default_action}`).join('|')],
  ([open]) => {
    if (open) reset();
  },
  { immediate: true }
);
</script>

<style scoped>
:global(.markdown-import-modal) {
  width: min(860px, 96vw);
  max-height: 90vh;
  display: flex;
  flex-direction: column;
  gap: 12px;
  overflow: hidden;
}

.markdown-transfer-modal__header,
.markdown-transfer-modal__row {
  display: flex;
  align-items: center;
  gap: 12px;
}

.markdown-transfer-modal__header {
  justify-content: space-between;
}

.markdown-transfer-modal__version {
  display: grid;
  gap: 6px;
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

.markdown-transfer-modal__meta {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
}

.markdown-transfer-modal__action {
  flex: 0 0 150px;
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

  :global(.markdown-import-modal) {
    width: 100%;
    height: calc(var(--app-vh, 1vh) * 100);
    max-height: calc(var(--app-vh, 1vh) * 100);
    border-radius: 0;
    padding-top: calc(12px + env(safe-area-inset-top));
    padding-right: 12px;
    padding-bottom: calc(12px + env(safe-area-inset-bottom));
    padding-left: 12px;
  }

  .markdown-transfer-modal__row {
    align-items: stretch;
    flex-direction: column;
  }

  .markdown-transfer-modal__action {
    width: 100%;
    flex-basis: auto;
  }
}
</style>
