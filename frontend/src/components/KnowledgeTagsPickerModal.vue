<template>
  <ModalWindow
    :open="open"
    backdrop-class="modal-backdrop--mobile-stretch"
    modal-class="knowledge-tag-picker"
    aria-label="Add tag"
    @cancel="close"
  >
        <div class="picker-header">
          <strong>{{ title }}</strong>
          <button type="button" aria-label="Close" @click="close">Close</button>
        </div>

        <div class="picker-body">
          <p v-if="loading" class="muted">Loading…</p>
          <p v-else-if="error" class="error-text">{{ error }}</p>
          <p v-else-if="!tags.length" class="muted">No tags found.</p>
          <KnowledgeTagsTree
            v-else
            :tags="tags"
            :selectedId="activeId"
            :selectedIds="selectedTagIds"
            :disabledIds="disabledTagIds"
            storageKey="ic.knowledge_tags.tree.open_state.v1"
            :defaultExpandDepth="2"
            @select="handleSelect"
          />
        </div>

        <div class="modal-actions">
          <button type="button" @click="close">Done</button>
        </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import KnowledgeTagsTree, { type KnowledgeTagTreeItem } from '@/components/KnowledgeTagsTree.vue';
import ModalWindow from '@/components/ModalWindow.vue';

const props = withDefaults(
  defineProps<{
    open: boolean;
    title?: string;
    tags: KnowledgeTagTreeItem[];
    selectedTagIds?: number[];
    disabledTagIds?: number[];
    loading?: boolean;
    error?: string | null;
  }>(),
  {
    title: 'Add tag',
    selectedTagIds: () => [],
    disabledTagIds: () => [],
    loading: false,
    error: null,
  }
);

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'select', tagId: number): void;
}>();

const activeId = ref<number | null>(null);
const disabledTagIds = computed(() => props.disabledTagIds || []);
const selectedTagIds = computed(() => props.selectedTagIds || []);

watch(
  () => props.open,
  (open) => {
    if (!open) {
      activeId.value = null;
      return;
    }
    activeId.value = null;
  }
);

function close() {
  activeId.value = null;
  emit('update:open', false);
}

function handleSelect(tagId: number) {
  activeId.value = tagId;
  emit('select', tagId);
}
</script>

<style scoped>
:global(.knowledge-tag-picker) {
  width: min(720px, 96vw);
  max-height: 90vh;
  overflow: hidden;
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.picker-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
}

.picker-body {
  flex: 1;
  min-height: 0;
  overflow: auto;
}

@media (max-width: 720px) {
  :global(.modal-backdrop--mobile-stretch) {
    padding: 0;
    align-items: stretch;
    justify-content: stretch;
  }

  :global(.knowledge-tag-picker) {
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
