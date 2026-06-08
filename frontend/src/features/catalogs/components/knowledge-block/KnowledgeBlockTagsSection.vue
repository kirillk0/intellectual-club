<template>
  <div class="stack">
    <div class="knowledge-block-section-header">
      <strong>Tags</strong>
      <button type="button" :disabled="saving" @click="emit('open-picker')">Add tag</button>
    </div>

    <p v-if="loading" class="muted">Loading…</p>
    <p v-else-if="error" class="error-text">{{ error }}</p>

    <div v-else class="list">
      <div v-for="tag in attachedTags" :key="tag.id" class="row knowledge-block-tag-row">
        <div class="knowledge-block-tag-row__main">
          <div class="knowledge-block-tag-row__name">{{ tag.full_name || tag.name }}</div>
        </div>
        <button type="button" :disabled="saving" @click="emit('remove-tag', tag.id)">Remove</button>
      </div>

      <p v-if="!attachedTags.length" class="muted">No tags.</p>
    </div>

    <p v-if="dirty" class="muted">Tag changes will be saved when you save the block.</p>

    <KnowledgeTagsPickerModal
      :open="modalOpen"
      :tags="allTags"
      :selectedTagIds="attachedTagIds"
      :loading="allTagsLoading"
      :error="allTagsError"
      title="Add tag"
      @update:open="emit('update:modalOpen', $event)"
      @select="emit('toggle-tag', $event)"
    />
  </div>
</template>

<script setup lang="ts">
import KnowledgeTagsPickerModal from '@/components/KnowledgeTagsPickerModal.vue';
import type { KnowledgeTagRow } from '@/features/catalogs/model/useKnowledgeBlockTagsDraft';

defineProps<{
  attachedTags: KnowledgeTagRow[];
  attachedTagIds: number[];
  allTags: KnowledgeTagRow[];
  allTagsLoading: boolean;
  allTagsError: string | null;
  modalOpen: boolean;
  loading: boolean;
  error: string | null;
  dirty: boolean;
  saving: boolean;
}>();

const emit = defineEmits<{
  (e: 'update:modalOpen', value: boolean): void;
  (e: 'open-picker'): void;
  (e: 'toggle-tag', tagId: number): void;
  (e: 'remove-tag', tagId: number): void;
}>();
</script>

<style scoped>
.knowledge-block-section-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
}

.knowledge-block-tag-row {
  justify-content: space-between;
  gap: 10px;
}

.knowledge-block-tag-row__main {
  min-width: 0;
}

.knowledge-block-tag-row__name {
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
</style>

