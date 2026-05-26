<template>
  <ModalWindow
    :open="open"
    backdrop-class="modal-backdrop--mobile-stretch"
    modal-class="llm-config-tag-picker"
    aria-label="Select tags"
    @cancel="cancel"
  >
        <div class="picker-header">
          <strong>{{ title }}</strong>
        </div>

        <label class="stack" style="gap: 6px">
          <span class="muted">Search</span>
          <input v-model="search" type="search" class="full" placeholder="Search tags" />
        </label>

        <div class="picker-body">
          <p v-if="loading" class="muted">Loading…</p>
          <p v-else-if="error" class="error-text">{{ error }}</p>
          <p v-else-if="!visibleTags.length" class="muted">No tags found.</p>
          <LlmConfigurationTagsList
            v-else
            :tags="visibleTags"
            :selectedIds="draftSelectedTagIds"
            @select="toggleDraft"
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
import LlmConfigurationTagsList, { type LlmConfigurationTagListItem } from '@/components/LlmConfigurationTagsList.vue';
import ModalWindow from '@/components/ModalWindow.vue';

const props = withDefaults(
  defineProps<{
    open: boolean;
    title?: string;
    tags: LlmConfigurationTagListItem[];
    selectedTagIds?: number[];
    loading?: boolean;
    error?: string | null;
  }>(),
  {
    title: 'Select tags',
    selectedTagIds: () => [],
    loading: false,
    error: null,
  }
);

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'toggle', tagId: number): void;
}>();

const search = ref('');
const draftSelectedTagIds = ref<number[]>([]);

const normalizeIds = (ids: number[] | undefined) =>
  Array.from(new Set((ids || []).filter((id) => Number.isInteger(id) && id > 0)));

watch(
  () => props.open,
  (open) => {
    if (!open) return;
    search.value = '';
    draftSelectedTagIds.value = normalizeIds(props.selectedTagIds);
  }
);

const visibleTags = computed(() => {
  const q = search.value.trim().toLowerCase();
  const tags = props.tags || [];
  if (!q) return tags;
  return tags.filter((tag) => String(tag.name || '').toLowerCase().includes(q));
});

function cancel() {
  emit('update:open', false);
}

function toggleDraft(tagId: number) {
  const set = new Set(draftSelectedTagIds.value);
  if (set.has(tagId)) set.delete(tagId);
  else set.add(tagId);
  draftSelectedTagIds.value = normalizeIds(Array.from(set));
}

function confirm() {
  const previous = new Set(normalizeIds(props.selectedTagIds));
  const next = new Set(draftSelectedTagIds.value);
  for (const tagId of previous) {
    if (!next.has(tagId)) emit('toggle', tagId);
  }
  for (const tagId of next) {
    if (!previous.has(tagId)) emit('toggle', tagId);
  }
  emit('update:open', false);
}
</script>

<style scoped>
:global(.llm-config-tag-picker) {
  width: min(640px, 96vw);
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

  :global(.llm-config-tag-picker) {
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
