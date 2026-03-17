<template>
  <Teleport to="body">
    <div v-if="open" class="modal-backdrop" @click.self="close">
      <div class="modal llm-config-tag-picker" role="dialog" aria-modal="true" aria-label="Select tags">
        <div class="picker-header">
          <strong>{{ title }}</strong>
          <button type="button" aria-label="Close" @click="close">Close</button>
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
            :selectedIds="selectedTagIds"
            @select="emit('toggle', $event)"
          />
        </div>

        <div class="modal-actions">
          <button type="button" @click="close">Done</button>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { Teleport } from 'vue';
import LlmConfigurationTagsList, { type LlmConfigurationTagListItem } from '@/components/LlmConfigurationTagsList.vue';

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

watch(
  () => props.open,
  (open) => {
    if (open) search.value = '';
  }
);

const visibleTags = computed(() => {
  const q = search.value.trim().toLowerCase();
  const tags = props.tags || [];
  if (!q) return tags;
  return tags.filter((tag) => String(tag.name || '').toLowerCase().includes(q));
});

function close() {
  emit('update:open', false);
}
</script>

<style scoped>
.llm-config-tag-picker {
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
  .modal-backdrop {
    padding: 0;
    align-items: stretch;
    justify-content: stretch;
  }

  .llm-config-tag-picker {
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
