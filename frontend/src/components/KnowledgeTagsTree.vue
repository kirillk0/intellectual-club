<template>
  <div class="tag-tree">
    <div
      v-for="row in rows"
      :key="row.tag.id"
      class="tag-tree__row"
      :class="{
        selected: row.tag.id === selectedId || selectedIdSet.has(row.tag.id),
        disabled: disabledIdSet.has(row.tag.id),
        'actions-open': row.tag.id === actionMenuTagId,
      }"
      :style="{ paddingLeft: `${row.depth * indentPx}px` }"
      @click="selectTag(row.tag.id)"
    >
      <button
        v-if="row.hasChildren"
        type="button"
        class="tag-tree__toggle-button"
        :aria-label="row.open ? 'Collapse' : 'Expand'"
        @click.stop="toggleOpen(row.tag.id, row.open)"
      >
        <span aria-hidden="true">{{ row.open ? '▾' : '▸' }}</span>
      </button>
      <span v-else class="tag-tree__toggle-spacer" aria-hidden="true"></span>

      <button
        type="button"
        class="tag-tree__label-button"
        :disabled="disabledIdSet.has(row.tag.id)"
      >
        {{ row.tag.name || row.tag.full_name || `Tag #${row.tag.id}` }}
      </button>

      <div v-if="showItemActions" class="menu tag-tree__actions">
        <button
          type="button"
          class="tag-tree__action-button"
          :ref="(el) => setActionButtonRef(row.tag.id, el)"
          :disabled="disabledIdSet.has(row.tag.id) || actionsDisabled"
          aria-label="Tag actions"
          title="Tag actions"
          @click.stop="toggleActionMenu(row.tag.id)"
        >
          ⋯
        </button>
      </div>
    </div>

    <div
      v-if="showNoTagsOption"
      class="tag-tree__row tag-tree__row--utility"
      :class="{ selected: noTagsSelected }"
      @click="selectNoTags"
    >
      <button type="button" class="tag-tree__label-button tag-tree__label-button--utility">
        {{ noTagsLabel }}
      </button>
    </div>
  </div>

  <Teleport to="body">
    <div
      v-if="showItemActions && actionMenuTag"
      ref="actionMenuRef"
      class="dropdown floating-dropdown"
      :style="actionMenuStyle"
    >
      <button class="menu-item" type="button" :disabled="actionsDisabled" @click="emitEdit">
        Edit
      </button>
      <button class="menu-item" type="button" :disabled="actionsDisabled" @click="emitAddChild">
        Add child
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

export type KnowledgeTagTreeItem = {
  id: number;
  name: string;
  full_name: string;
  parent_id: number | null;
};

type OpenState = Record<string, boolean>;

type TreeRow = {
  tag: KnowledgeTagTreeItem;
  depth: number;
  hasChildren: boolean;
  open: boolean;
};

const props = withDefaults(
  defineProps<{
    tags: KnowledgeTagTreeItem[];
    selectedId?: number | null;
    selectedIds?: number[];
    disabledIds?: number[];
    showNoTagsOption?: boolean;
    noTagsSelected?: boolean;
    noTagsLabel?: string;
    storageKey?: string;
    defaultExpandDepth?: number;
    indentPx?: number;
    expandAll?: boolean;
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
    storageKey: 'ic.knowledge_tags.tree.open_state.v3',
    defaultExpandDepth: 1,
    indentPx: 14,
    expandAll: false,
    showItemActions: false,
    actionsDisabled: false,
  }
);

const emit = defineEmits<{
  (e: 'select', id: number): void;
  (e: 'select-no-tags'): void;
  (e: 'edit', id: number): void;
  (e: 'add-child', id: number): void;
  (e: 'delete', id: number): void;
}>();

const openState = ref<OpenState>({});
const actionMenuTagId = ref<number | null>(null);
const actionMenuRef = ref<HTMLElement | null>(null);
const actionMenuStyle = ref<Record<string, string>>({});
const actionButtonRefs = new Map<number, HTMLElement>();

function loadOpenState() {
  const key = props.storageKey;
  if (!key) return {};

  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== 'object') return {};

    const out: OpenState = {};
    for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
      if (typeof v === 'boolean') out[k] = v;
    }
    return out;
  } catch {
    return {};
  }
}

function persistOpenState(next: OpenState) {
  const key = props.storageKey;
  if (!key) return;
  try {
    window.localStorage.setItem(key, JSON.stringify(next));
  } catch {
    // ignore
  }
}

onMounted(() => {
  openState.value = loadOpenState();
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
  () => props.storageKey,
  () => {
    openState.value = loadOpenState();
  }
);

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

const tagById = computed(() => {
  const map = new Map<number, KnowledgeTagTreeItem>();
  for (const t of props.tags || []) map.set(t.id, t);
  return map;
});

const childrenByParent = computed(() => {
  const map = new Map<number | null, KnowledgeTagTreeItem[]>();
  for (const t of props.tags || []) {
    const parentId = t.parent_id ?? null;
    const list = map.get(parentId) || [];
    list.push(t);
    map.set(parentId, list);
  }

  for (const [k, list] of map.entries()) {
    list.sort((a, b) => {
      const aKey = (a.name || a.full_name || '').toLowerCase();
      const bKey = (b.name || b.full_name || '').toLowerCase();
      return aKey.localeCompare(bKey) || a.id - b.id;
    });
    map.set(k, list);
  }

  return map;
});

const roots = computed(() => {
  const byId = tagById.value;
  return (props.tags || [])
    .filter((t) => t.parent_id === null || t.parent_id === undefined || !byId.has(t.parent_id))
    .sort((a, b) => {
      const aKey = (a.name || a.full_name || '').toLowerCase();
      const bKey = (b.name || b.full_name || '').toLowerCase();
      return aKey.localeCompare(bKey) || a.id - b.id;
    });
});

const forcedOpenIds = computed(() => {
  const selectedId = props.selectedId ?? null;
  const byId = tagById.value;
  const out = new Set<number>();

  if (!selectedId) return out;

  const visited = new Set<number>();
  let currentId: number | null = selectedId;

  while (currentId) {
    const tag = byId.get(currentId);
    if (!tag) break;
    const parentId = tag.parent_id ?? null;
    if (!parentId) break;
    if (visited.has(parentId)) break;
    visited.add(parentId);
    out.add(parentId);
    currentId = parentId;
  }

  return out;
});

function isOpen(id: number, depth: number) {
  if (props.expandAll) return true;
  if (forcedOpenIds.value.has(id)) return true;

  const persisted = openState.value[String(id)];
  if (typeof persisted === 'boolean') return persisted;

  return depth + 1 <= (props.defaultExpandDepth ?? 0);
}

const rows = computed<TreeRow[]>(() => {
  const byParent = childrenByParent.value;

  const pushRows = (parentId: number | null, depth: number, out: TreeRow[]) => {
    const items = parentId === null ? roots.value : byParent.get(parentId) || [];

    for (const tag of items) {
      const children = byParent.get(tag.id) || [];
      const hasChildren = children.length > 0;
      const open = hasChildren ? isOpen(tag.id, depth) : false;
      out.push({ tag, depth, hasChildren, open });

      if (hasChildren && open) pushRows(tag.id, depth + 1, out);
    }
  };

  const out: TreeRow[] = [];
  pushRows(null, 0, out);

  return out;
});

const disabledIdSet = computed(() => new Set<number>(props.disabledIds || []));
const selectedIdSet = computed(() => new Set<number>(props.selectedIds || []));
const actionMenuTag = computed(() => {
  const tagId = actionMenuTagId.value;
  if (!tagId) return null;
  return tagById.value.get(tagId) || null;
});

function toggleOpen(id: number, currentOpen: boolean) {
  const next = { ...(openState.value || {}) };
  next[String(id)] = !currentOpen;
  openState.value = next;
  persistOpenState(next);
}

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

function selectTag(id: number) {
  if (!id) return;
  if (disabledIdSet.value.has(id)) return;
  emit('select', id);
}

function selectNoTags() {
  emit('select-no-tags');
}

function emitEdit() {
  if (!actionMenuTagId.value) return;
  emit('edit', actionMenuTagId.value);
  closeActionMenu();
}

function emitAddChild() {
  if (!actionMenuTagId.value) return;
  emit('add-child', actionMenuTagId.value);
  closeActionMenu();
}

function emitDelete() {
  if (!actionMenuTagId.value) return;
  emit('delete', actionMenuTagId.value);
  closeActionMenu();
}
</script>

<style scoped>
.tag-tree__actions {
  margin-left: auto;
  flex: 0 0 auto;
}

.tag-tree__action-button {
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

.tag-tree__action-button:hover {
  background: var(--color-surface-hover);
  border-color: var(--color-border-strong);
}

.tag-tree__row.selected .tag-tree__action-button,
.tag-tree__row.actions-open .tag-tree__action-button {
  color: var(--color-primary-contrast);
}

.tag-tree__row.selected .tag-tree__action-button:hover,
.tag-tree__row.actions-open .tag-tree__action-button,
.tag-tree__row.actions-open .tag-tree__action-button:hover {
  background: rgba(255, 255, 255, 0.12);
  border-color: rgba(255, 255, 255, 0.2);
}
</style>
