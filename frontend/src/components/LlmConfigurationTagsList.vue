<template>
  <div class="list llm-config-tags-list">
    <button
      v-if="showNoTagsOption"
      type="button"
      :class="['row', 'llm-config-tags-list__row', noTagsSelected && 'llm-config-tags-list__row--active']"
      @click="emit('select-no-tags')"
    >
      <span class="llm-config-tags-list__label">{{ noTagsLabel }}</span>
    </button>

    <div
      v-for="tag in sortedTags"
      :key="tag.id"
      :class="[
        'row',
        'llm-config-tags-list__row',
        isSelected(tag.id) && 'llm-config-tags-list__row--active',
        isDisabled(tag.id) && 'llm-config-tags-list__row--disabled',
      ]"
    >
      <button
        type="button"
        class="llm-config-tags-list__main"
        :disabled="isDisabled(tag.id)"
        @click="emit('select', tag.id)"
      >
        <span class="llm-config-tags-list__label">{{ tag.name || `Tag #${tag.id}` }}</span>
      </button>

      <div v-if="showItemActions" class="llm-config-tags-list__actions">
        <button type="button" :disabled="actionsDisabled" @click.stop="emit('rename', tag.id)">Rename</button>
        <button type="button" class="danger" :disabled="actionsDisabled" @click.stop="emit('delete', tag.id)">
          Delete
        </button>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

export type LlmConfigurationTagListItem = {
  id: number;
  name: string;
};

const props = withDefaults(
  defineProps<{
    tags: LlmConfigurationTagListItem[];
    selectedId?: number | null;
    selectedIds?: number[];
    disabledIds?: number[];
    showNoTagsOption?: boolean;
    noTagsSelected?: boolean;
    noTagsLabel?: string;
    showItemActions?: boolean;
    actionsDisabled?: boolean;
  }>(),
  {
    selectedId: null,
    selectedIds: () => [],
    disabledIds: () => [],
    showNoTagsOption: false,
    noTagsSelected: false,
    noTagsLabel: 'No tags',
    showItemActions: false,
    actionsDisabled: false,
  }
);

const emit = defineEmits<{
  (e: 'select', tagId: number): void;
  (e: 'select-no-tags'): void;
  (e: 'rename', tagId: number): void;
  (e: 'delete', tagId: number): void;
}>();

const selectedIdsSet = computed(() => new Set(props.selectedIds || []));
const disabledIdsSet = computed(() => new Set(props.disabledIds || []));

const sortedTags = computed(() => {
  const list = [...(props.tags || [])];
  list.sort((a, b) => (a.name || '').localeCompare(b.name || '') || a.id - b.id);
  return list;
});

const isSelected = (tagId: number) => props.selectedId === tagId || selectedIdsSet.value.has(tagId);
const isDisabled = (tagId: number) => disabledIdsSet.value.has(tagId);
</script>

<style scoped>
.llm-config-tags-list__row {
  gap: 8px;
  align-items: center;
  min-height: 44px;
}

.llm-config-tags-list__row--active {
  border-color: #cfe1ff;
  background: #f3f8ff;
}

.llm-config-tags-list__row--disabled {
  opacity: 0.6;
}

.llm-config-tags-list__main {
  flex: 1;
  min-width: 0;
  display: flex;
  align-items: center;
  justify-content: flex-start;
  background: transparent;
  border: none;
  padding: 0;
  color: inherit;
  text-align: left;
}

.llm-config-tags-list__main:disabled {
  cursor: default;
}

.llm-config-tags-list__label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-weight: 600;
}

.llm-config-tags-list__actions {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-left: auto;
}

@media (max-width: 640px) {
  .llm-config-tags-list__row {
    flex-wrap: wrap;
  }

  .llm-config-tags-list__actions {
    width: 100%;
    justify-content: flex-end;
  }
}
</style>
