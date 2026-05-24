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
        actionMenuTagId === tag.id && 'llm-config-tags-list__row--actions-open',
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

      <div v-if="showItemActions" class="menu llm-config-tags-list__actions">
        <button
          type="button"
          class="llm-config-tags-list__action-button"
          :ref="(el) => setActionButtonRef(tag.id, el)"
          :disabled="isDisabled(tag.id) || actionsDisabled"
          aria-label="Tag actions"
          title="Tag actions"
          @click.stop="toggleActionMenu(tag.id)"
        >
          ⋯
        </button>
      </div>
    </div>
  </div>

  <Teleport to="body">
    <div
      v-if="showItemActions && actionMenuTag"
      ref="actionMenuRef"
      class="dropdown floating-dropdown"
      :style="actionMenuStyle"
    >
      <button class="menu-item" type="button" :disabled="actionsDisabled" @click="emitRename">
        Rename
      </button>
      <button class="menu-item danger" type="button" :disabled="actionsDisabled" @click="emitDelete">
        Delete
      </button>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { Teleport } from 'vue';

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
const actionMenuTagId = ref<number | null>(null);
const actionMenuRef = ref<HTMLElement | null>(null);
const actionMenuStyle = ref<Record<string, string>>({});
const actionButtonRefs = new Map<number, HTMLElement>();

const sortedTags = computed(() => {
  const list = [...(props.tags || [])];
  list.sort((a, b) => (a.name || '').localeCompare(b.name || '') || a.id - b.id);
  return list;
});

const tagById = computed(() => {
  const map = new Map<number, LlmConfigurationTagListItem>();
  for (const tag of props.tags || []) map.set(tag.id, tag);
  return map;
});

const actionMenuTag = computed(() => {
  const tagId = actionMenuTagId.value;
  if (!tagId) return null;
  return tagById.value.get(tagId) || null;
});

const isSelected = (tagId: number) => props.selectedId === tagId || selectedIdsSet.value.has(tagId);
const isDisabled = (tagId: number) => disabledIdsSet.value.has(tagId);

function setActionButtonRef(tagId: number, element: Element | null) {
  if (element instanceof HTMLElement) {
    actionButtonRefs.set(tagId, element);
    return;
  }

  actionButtonRefs.delete(tagId);
}

function closeActionMenu() {
  actionMenuTagId.value = null;
  actionMenuStyle.value = {};
}

function toggleActionMenu(tagId: number) {
  if (actionMenuTagId.value === tagId) {
    closeActionMenu();
    return;
  }

  actionMenuTagId.value = tagId;
  updateActionMenuPosition();
}

function handleActionMenuClickOutside(event: MouseEvent) {
  const target = event.target as Node | null;
  if (!target) return;
  if (actionMenuRef.value?.contains(target)) return;

  const activeButton = actionMenuTagId.value ? actionButtonRefs.get(actionMenuTagId.value) : null;
  if (activeButton?.contains(target)) return;

  closeActionMenu();
}

function updateActionMenuPosition() {
  if (!actionMenuTagId.value) return;

  const button = actionButtonRefs.get(actionMenuTagId.value);
  if (!button) return;

  const rect = button.getBoundingClientRect();
  const viewportPadding = 8;
  const minWidth = 160;
  const maxWidth = Math.max(minWidth, window.innerWidth - viewportPadding * 2);
  const width = Math.min(180, maxWidth);
  const left = Math.min(
    Math.max(viewportPadding, rect.right - width),
    Math.max(viewportPadding, window.innerWidth - width - viewportPadding)
  );

  actionMenuStyle.value = {
    position: 'fixed',
    top: `${rect.bottom + 6}px`,
    left: `${left}px`,
    width: `${width}px`,
    maxWidth: `${maxWidth}px`,
    zIndex: '2000',
  };
}

function emitRename() {
  if (!actionMenuTagId.value) return;
  emit('rename', actionMenuTagId.value);
  closeActionMenu();
}

function emitDelete() {
  if (!actionMenuTagId.value) return;
  emit('delete', actionMenuTagId.value);
  closeActionMenu();
}

onMounted(() => {
  document.addEventListener('click', handleActionMenuClickOutside);
  window.addEventListener('resize', updateActionMenuPosition);
  window.addEventListener('scroll', updateActionMenuPosition, true);
});

onBeforeUnmount(() => {
  document.removeEventListener('click', handleActionMenuClickOutside);
  window.removeEventListener('resize', updateActionMenuPosition);
  window.removeEventListener('scroll', updateActionMenuPosition, true);
});

watch(
  () => props.showItemActions,
  (enabled) => {
    if (!enabled) closeActionMenu();
  }
);

watch(
  () => props.tags,
  (nextTags) => {
    if (!actionMenuTagId.value) return;
    if (!nextTags.some((tag) => tag.id === actionMenuTagId.value)) closeActionMenu();
  }
);
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
  margin-left: auto;
  flex: 0 0 auto;
}

.llm-config-tags-list__action-button {
  width: 28px;
  height: 28px;
  padding: 0;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: 1px solid transparent;
  border-radius: 8px;
  background: transparent;
  color: inherit;
  font-size: 18px;
  line-height: 1;
}

.llm-config-tags-list__action-button:hover {
  background: rgba(0, 0, 0, 0.06);
  border-color: rgba(0, 0, 0, 0.12);
}

.llm-config-tags-list__row--active .llm-config-tags-list__action-button,
.llm-config-tags-list__row--actions-open .llm-config-tags-list__action-button {
  color: #111;
}

.llm-config-tags-list__row--active .llm-config-tags-list__action-button:hover,
.llm-config-tags-list__row--actions-open .llm-config-tags-list__action-button,
.llm-config-tags-list__row--actions-open .llm-config-tags-list__action-button:hover {
  background: rgba(0, 0, 0, 0.06);
  border-color: rgba(0, 0, 0, 0.12);
}
</style>
