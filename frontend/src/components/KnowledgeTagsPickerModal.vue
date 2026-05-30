<template>
  <ModalWindow
    :open="open"
    backdrop-class="modal-backdrop--mobile-stretch"
    modal-class="knowledge-tag-picker"
    aria-label="Add tag"
    @cancel="cancel"
  >
        <div class="picker-header">
          <strong>{{ title }}</strong>
        </div>

        <div class="picker-body">
          <p v-if="loading" class="muted">Loading…</p>
          <p v-else-if="error" class="error-text">{{ error }}</p>
          <p v-else-if="!tags.length" class="muted">No tags found.</p>
          <KnowledgeTagsTree
            v-else
            :tags="tags"
            :selectedId="selectionMode === 'single' ? activeId : null"
            :selectedIds="draftSelectedTagIds"
            :disabledIds="disabledTagIds"
            storageKey="ic.knowledge_tags.tree.open_state.v3"
            :defaultExpandDepth="1"
            @select="handleSelect"
          />
        </div>

        <div class="modal-actions">
          <div class="spacer"></div>
          <button type="button" @click="cancel">Cancel</button>
          <button class="primary" type="button" @click="confirm">Done</button>
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
    selectionMode?: 'multi' | 'single';
    loading?: boolean;
    error?: string | null;
  }>(),
  {
    title: 'Add tag',
    selectedTagIds: () => [],
    disabledTagIds: () => [],
    selectionMode: 'multi',
    loading: false,
    error: null,
  }
);

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'select', tagId: number): void;
}>();

const activeId = ref<number | null>(null);
const draftSelectedTagIds = ref<number[]>([]);
const disabledTagIds = computed(() => props.disabledTagIds || []);

const normalizeIds = (ids: number[] | undefined) =>
  Array.from(new Set((ids || []).filter((id) => Number.isInteger(id) && id > 0)));

watch(
  () => props.open,
  (open) => {
    if (!open) {
      activeId.value = null;
      return;
    }
    activeId.value = null;
    draftSelectedTagIds.value = normalizeIds(props.selectedTagIds);
  }
);

function cancel() {
  activeId.value = null;
  emit('update:open', false);
}

function handleSelect(tagId: number) {
  activeId.value = tagId;
  if (props.selectionMode === 'single') {
    draftSelectedTagIds.value = [tagId];
    return;
  }

  const set = new Set(draftSelectedTagIds.value);
  if (set.has(tagId)) set.delete(tagId);
  else set.add(tagId);
  draftSelectedTagIds.value = normalizeIds(Array.from(set));
}

function confirm() {
  const previousIds = normalizeIds(props.selectedTagIds);
  const nextIds = normalizeIds(draftSelectedTagIds.value);

  if (props.selectionMode === 'single') {
    const nextId = nextIds[0] ?? null;
    if (nextId && nextId !== (previousIds[0] ?? null)) emit('select', nextId);
    cancel();
    return;
  }

  const previous = new Set(previousIds);
  const next = new Set(nextIds);
  for (const tagId of previous) {
    if (!next.has(tagId)) emit('select', tagId);
  }
  for (const tagId of next) {
    if (!previous.has(tagId)) emit('select', tagId);
  }
  cancel();
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
