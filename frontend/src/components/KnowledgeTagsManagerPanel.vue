<template>
  <section class="card stack catalog-tags-card knowledge-tags-panel">
    <div class="knowledge-tags-panel__header">
      <strong>{{ title }}</strong>
      <div class="knowledge-tags-panel__header-actions">
        <button
          type="button"
          class="icon-button knowledge-tags-panel__add-button"
          :disabled="mutationLoading"
          aria-label="Add root tag"
          title="Add root tag"
          @click="startCreateRoot"
        >
          +
        </button>
        <button type="button" class="link" :disabled="!hasActiveFilter || mutationLoading" @click="emit('clear-filter')">
          Clear
        </button>
        <slot name="header-extra"></slot>
      </div>
    </div>

    <div class="knowledge-tags-panel__filter">
      <input
        v-model="tagFilter"
        type="search"
        class="full"
        placeholder="Filter tags"
        aria-label="Filter tags"
      />
      <button v-if="tagFilter" type="button" @click="tagFilter = ''">Clear</button>
    </div>

    <form v-if="editorMode" class="knowledge-tags-panel__editor" @submit.prevent="submitEditor">
      <div class="knowledge-tags-panel__editor-title">{{ editorTitle }}</div>
      <p v-if="editorContext" class="muted knowledge-tags-panel__editor-context">{{ editorContext }}</p>

      <label class="knowledge-tags-panel__editor-field">
        <span>Name</span>
        <input
          ref="editorInputRef"
          v-model="editorName"
          type="text"
          class="full"
          placeholder="Tag name"
          :disabled="mutationLoading"
          @input="editorError = null"
        />
      </label>

      <p v-if="editorError" class="error-text">{{ editorError }}</p>

      <div class="knowledge-tags-panel__editor-actions">
        <button type="button" :disabled="mutationLoading" @click="cancelEditor">Cancel</button>
        <button type="submit" class="primary" :disabled="submitDisabled">
          {{ editorSubmitLabel }}
        </button>
      </div>
    </form>

    <p v-if="tagsLoading" class="muted">Loading…</p>
    <p v-else-if="tagsError" class="error-text">{{ tagsError }}</p>
    <KnowledgeTagsTree
      v-else
      :tags="visibleTags"
      :selectedId="selectedId"
      :showNoTagsOption="showTreeNoTagsOption"
      :noTagsSelected="noTagsSelected"
      :noTagsLabel="noTagsLabel"
      :storageKey="storageKey"
      :defaultExpandDepth="defaultExpandDepth"
      :expandAll="hasTagFilter"
      :showItemActions="true"
      :actionsDisabled="mutationLoading"
      @select="emit('select', $event)"
      @select-no-tags="emit('select-no-tags')"
      @edit="openEditModal"
      @add-child="startCreateChild"
      @delete="deleteTag"
    />

    <p v-if="visibleTagsEmptyState" class="muted">{{ visibleTagsEmptyState }}</p>
  </section>

  <ModalWindow
    :open="editModalOpen"
    modal-class="knowledge-tag-edit-modal"
    aria-label="Edit tag"
    :cancel-disabled="mutationLoading"
    @cancel="cancelEditModal"
  >
    <form class="tag-edit-modal" @submit.prevent="submitEditModal">
      <div class="tag-edit-modal__header">
        <strong>Edit tag</strong>
        <p v-if="currentEditTagPath" class="muted">{{ currentEditTagPath }}</p>
      </div>

      <label class="tag-edit-modal__field">
        <span>Name</span>
        <input
          ref="editModalInputRef"
          v-model="editModalName"
          type="text"
          class="full"
          placeholder="Tag name"
          :disabled="mutationLoading"
          @input="editModalError = null"
        />
      </label>

      <label class="tag-edit-modal__field">
        <span>Parent</span>
        <select v-model="editModalParentId" class="full" :disabled="mutationLoading" @change="editModalError = null">
          <option :value="''">No parent (root)</option>
          <option v-for="tag in editParentOptions" :key="tag.id" :value="tag.id">
            {{ tag.full_name || tag.name || `Tag #${tag.id}` }}
          </option>
        </select>
      </label>

      <p v-if="editModalError" class="error-text">{{ editModalError }}</p>

      <div class="modal-actions">
        <div class="spacer"></div>
        <button type="button" :disabled="mutationLoading" @click="cancelEditModal">Cancel</button>
        <button type="submit" class="primary" :disabled="editModalSubmitDisabled">
          {{ mutationLoading ? 'Saving…' : 'Save' }}
        </button>
      </div>
    </form>
  </ModalWindow>
</template>

<script setup lang="ts">
import { computed, nextTick, onMounted, ref } from 'vue';
import KnowledgeTagsTree, { type KnowledgeTagTreeItem } from '@/components/KnowledgeTagsTree.vue';
import ModalWindow from '@/components/ModalWindow.vue';
import {
  fieldErrorsFromJsonApiErrors,
  formErrorsFromJsonApiErrors,
  getJsonApiErrors,
  jsonApiCreate,
  jsonApiDelete,
  jsonApiList,
  jsonApiUpdate,
  relationshipId,
  toIntId,
  type JsonApiResource,
} from '@/api/jsonApi';

type TagEditorMode = 'create-root' | 'create-child';

const props = withDefaults(
  defineProps<{
    title?: string;
    selectedId?: number | null;
    noTagsSelected?: boolean;
    hasActiveFilter?: boolean;
    showNoTagsOption?: boolean;
    noTagsLabel?: string;
    storageKey?: string;
    defaultExpandDepth?: number;
  }>(),
  {
    title: 'Tags',
    selectedId: null,
    noTagsSelected: false,
    hasActiveFilter: false,
    showNoTagsOption: true,
    noTagsLabel: 'No tags',
    storageKey: 'ic.knowledge_tags.tree.open_state.v3',
    defaultExpandDepth: 1,
  }
);

const emit = defineEmits<{
  (e: 'select', id: number): void;
  (e: 'select-no-tags'): void;
  (e: 'clear-filter'): void;
}>();

const tagsLoading = ref(false);
const tagsError = ref<string | null>(null);
const tags = ref<KnowledgeTagTreeItem[]>([]);
const mutationLoading = ref(false);
const tagFilter = ref('');

const editorMode = ref<TagEditorMode | null>(null);
const editorTagId = ref<number | null>(null);
const editorName = ref('');
const editorError = ref<string | null>(null);
const editorInputRef = ref<HTMLInputElement | null>(null);
const editModalOpen = ref(false);
const editModalTagId = ref<number | null>(null);
const editModalName = ref('');
const editModalParentId = ref<number | ''>('');
const editModalError = ref<string | null>(null);
const editModalInputRef = ref<HTMLInputElement | null>(null);

function normalizeTagFilter(value: string) {
  return value.trim().toLowerCase();
}

function parseTagRow(resource: JsonApiResource): KnowledgeTagTreeItem | null {
  const id = toIntId(resource.id);
  if (!id) return null;

  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const parentId =
    (typeof attrs.parent_id === 'number' ? attrs.parent_id : toIntId(attrs.parent_id as string | number | null)) ??
    relationshipId(resource, 'parent');

  return {
    id,
    name: String(attrs.name || '').trim(),
    full_name: String(attrs.full_name || '').trim(),
    parent_id: parentId ?? null,
  };
}

function describeMutationError(error: unknown, fallbackMessage: string) {
  const jsonApiErrors = getJsonApiErrors(error);
  if (jsonApiErrors?.length) {
    const fieldErrors = fieldErrorsFromJsonApiErrors(jsonApiErrors);

    for (const field of ['name', 'parent_id']) {
      const messages = fieldErrors[field];
      if (messages?.length) return messages.join(' ');
    }

    const formErrors = formErrorsFromJsonApiErrors(jsonApiErrors);
    if (formErrors.length) return formErrors.join(' ');
  }

  return error instanceof Error ? error.message : fallbackMessage;
}

const currentEditorTag = computed(() => {
  const id = editorTagId.value;
  if (!id) return null;
  return tags.value.find((tag) => tag.id === id) || null;
});

const currentEditTag = computed(() => {
  const id = editModalTagId.value;
  if (!id) return null;
  return tags.value.find((tag) => tag.id === id) || null;
});

const hasTagFilter = computed(() => normalizeTagFilter(tagFilter.value).length > 0);
const tagById = computed(() => {
  const map = new Map<number, KnowledgeTagTreeItem>();
  for (const tag of tags.value) map.set(tag.id, tag);
  return map;
});
const childrenByParent = computed(() => {
  const map = new Map<number | null, KnowledgeTagTreeItem[]>();

  for (const tag of tags.value) {
    const parentId = tag.parent_id ?? null;
    const children = map.get(parentId) || [];
    children.push(tag);
    map.set(parentId, children);
  }

  return map;
});

function sortTagsByPath(list: KnowledgeTagTreeItem[]) {
  return [...list].sort((a, b) => {
    const left = (a.full_name || a.name || '').toLowerCase();
    const right = (b.full_name || b.name || '').toLowerCase();
    return left.localeCompare(right) || a.id - b.id;
  });
}

function collectAncestorIds(tagId: number, byId: Map<number, KnowledgeTagTreeItem>, out: Set<number>) {
  const visited = new Set<number>();
  let current = byId.get(tagId) || null;

  while (current?.parent_id) {
    const parentId = current.parent_id;
    if (!parentId || visited.has(parentId)) break;
    visited.add(parentId);
    out.add(parentId);
    current = byId.get(parentId) || null;
  }
}

function collectDescendantIds(tagId: number, byParent: Map<number | null, KnowledgeTagTreeItem[]>, out: Set<number>) {
  const stack = [tagId];
  const visited = new Set<number>();

  while (stack.length) {
    const currentId = stack.pop();
    if (!currentId) continue;
    const children = byParent.get(currentId) || [];

    for (const child of children) {
      if (visited.has(child.id)) continue;
      visited.add(child.id);
      out.add(child.id);
      stack.push(child.id);
    }
  }
}

function descendantIdSet(tagId: number) {
  const out = new Set<number>();
  collectDescendantIds(tagId, childrenByParent.value, out);
  return out;
}

const visibleTags = computed(() => {
  const filter = normalizeTagFilter(tagFilter.value);
  if (!filter) return tags.value;

  const visibleIds = new Set<number>();
  const byId = tagById.value;
  const byParent = childrenByParent.value;

  for (const tag of tags.value) {
    const haystack = `${tag.name} ${tag.full_name}`.toLowerCase();
    if (!haystack.includes(filter)) continue;

    visibleIds.add(tag.id);
    collectAncestorIds(tag.id, byId, visibleIds);
    collectDescendantIds(tag.id, byParent, visibleIds);
  }

  return tags.value.filter((tag) => visibleIds.has(tag.id));
});

const showTreeNoTagsOption = computed(() => props.showNoTagsOption && !hasTagFilter.value);
const visibleTagsEmptyState = computed(() => {
  if (tagsLoading.value || tagsError.value) return '';
  if (hasTagFilter.value) return visibleTags.value.length ? '' : 'No tags match the current filter.';
  return tags.value.length ? '' : 'No tags.';
});
const editParentOptions = computed(() => {
  const tag = currentEditTag.value;
  if (!tag) return [];

  const descendants = descendantIdSet(tag.id);
  return sortTagsByPath(tags.value.filter((item) => item.id !== tag.id && !descendants.has(item.id)));
});

const currentEditTagPath = computed(() => currentEditTag.value?.full_name || currentEditTag.value?.name || '');

const editorTitle = computed(() => {
  switch (editorMode.value) {
    case 'create-root':
      return 'New tag';
    case 'create-child':
      return 'Add child tag';
    default:
      return '';
  }
});

const editorContext = computed(() => {
  const tag = currentEditorTag.value;
  if (!tag) return '';

  if (editorMode.value === 'create-child') return `Parent: ${tag.full_name || tag.name}`;
  return '';
});

const editorSubmitLabel = computed(() => 'Create');
const submitDisabled = computed(() => mutationLoading.value || !editorName.value.trim());
const editModalSubmitDisabled = computed(() => mutationLoading.value || !editModalName.value.trim() || !currentEditTag.value);

async function focusEditorInput() {
  await nextTick();
  editorInputRef.value?.focus();
  editorInputRef.value?.select();
}

function resetEditor() {
  editorMode.value = null;
  editorTagId.value = null;
  editorName.value = '';
  editorError.value = null;
}

function resetEditModal() {
  editModalOpen.value = false;
  editModalTagId.value = null;
  editModalName.value = '';
  editModalParentId.value = '';
  editModalError.value = null;
}

function cancelEditor() {
  resetEditor();
}

function cancelEditModal() {
  if (mutationLoading.value) return;
  resetEditModal();
}

function startCreateRoot() {
  editorMode.value = 'create-root';
  editorTagId.value = null;
  editorName.value = '';
  editorError.value = null;
  void focusEditorInput();
}

async function focusEditModalInput() {
  await nextTick();
  editModalInputRef.value?.focus();
  editModalInputRef.value?.select();
}

function openEditModal(tagId: number) {
  const tag = tags.value.find((row) => row.id === tagId);
  if (!tag) return;

  resetEditor();
  editModalTagId.value = tagId;
  editModalName.value = tag.name || '';
  editModalParentId.value = tag.parent_id ?? '';
  editModalError.value = null;
  editModalOpen.value = true;
  void focusEditModalInput();
}

function startCreateChild(tagId: number) {
  const tag = tags.value.find((row) => row.id === tagId);
  if (!tag) return;

  editorMode.value = 'create-child';
  editorTagId.value = tagId;
  editorName.value = '';
  editorError.value = null;
  void focusEditorInput();
}

async function loadTags() {
  tagsLoading.value = true;
  tagsError.value = null;

  try {
    const params = new URLSearchParams();
    params.set('sort', 'full_name');
    const payload = await jsonApiList('/api/ash/knowledge-tags', params);
    tags.value = (payload.data || []).map(parseTagRow).filter((tag): tag is KnowledgeTagTreeItem => Boolean(tag));
  } catch (error) {
    console.error(error);
    tagsError.value = error instanceof Error ? error.message : 'Failed to load tags.';
  } finally {
    tagsLoading.value = false;
  }
}

async function submitEditor() {
  if (!editorMode.value) return;

  const name = editorName.value.trim();
  if (!name) {
    editorError.value = 'Name is required.';
    return;
  }

  mutationLoading.value = true;
  editorError.value = null;
  tagsError.value = null;

  try {
    if (editorMode.value === 'create-root') {
      await jsonApiCreate('/api/ash/knowledge-tags', 'knowledge-tags', {
        name,
        parent_id: null,
      });
    } else if (editorMode.value === 'create-child') {
      if (!editorTagId.value) throw new Error('Parent tag not found.');

      await jsonApiCreate('/api/ash/knowledge-tags', 'knowledge-tags', {
        name,
        parent_id: editorTagId.value,
      });
    }

    resetEditor();
    await loadTags();
  } catch (error) {
    console.error(error);
    editorError.value = describeMutationError(error, 'Failed to save tag.');
  } finally {
    mutationLoading.value = false;
  }
}

async function submitEditModal() {
  const tag = currentEditTag.value;
  if (!tag) {
    editModalError.value = 'Tag not found.';
    return;
  }

  const name = editModalName.value.trim();
  if (!name) {
    editModalError.value = 'Name is required.';
    return;
  }

  const parentId = editModalParentId.value === '' ? null : Number(editModalParentId.value);

  mutationLoading.value = true;
  editModalError.value = null;
  tagsError.value = null;

  try {
    await jsonApiUpdate('/api/ash/knowledge-tags', 'knowledge-tags', tag.id, {
      name,
      parent_id: parentId,
    });

    resetEditModal();
    await loadTags();
  } catch (error) {
    console.error(error);
    editModalError.value = describeMutationError(error, 'Failed to save tag.');
  } finally {
    mutationLoading.value = false;
  }
}

async function deleteTag(tagId: number) {
  const tag = tags.value.find((row) => row.id === tagId);
  const label = tag?.full_name || tag?.name || `Tag #${tagId}`;
  if (!window.confirm(`Delete tag "${label}"?`)) return;

  mutationLoading.value = true;
  editorError.value = null;
  tagsError.value = null;

  try {
    const shouldClearFilter = props.selectedId === tagId;

    await jsonApiDelete('/api/ash/knowledge-tags', tagId);

    if (editorTagId.value === tagId) resetEditor();
    if (editModalTagId.value === tagId) resetEditModal();

    await loadTags();

    if (shouldClearFilter) {
      emit('clear-filter');
    }
  } catch (error) {
    console.error(error);
    tagsError.value = describeMutationError(error, 'Failed to delete tag.');
  } finally {
    mutationLoading.value = false;
  }
}

onMounted(() => {
  void loadTags();
});
</script>

<style scoped>
.knowledge-tags-panel {
  gap: 10px;
}

.knowledge-tags-panel__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.knowledge-tags-panel__header-actions {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  flex-wrap: nowrap;
}

.knowledge-tags-panel__filter {
  display: flex;
  align-items: center;
  gap: 8px;
}

.knowledge-tags-panel__add-button {
  width: 30px;
  height: 30px;
  font-size: 20px;
}

.knowledge-tags-panel__editor {
  display: grid;
  gap: 8px;
  padding: 10px;
  border: 1px solid #e9e9e9;
  border-radius: 12px;
  background: #fafafa;
}

.knowledge-tags-panel__editor-title {
  font-weight: 700;
}

.knowledge-tags-panel__editor-context {
  margin: 0;
}

.knowledge-tags-panel__editor-field {
  display: grid;
  gap: 6px;
}

.knowledge-tags-panel__editor-actions {
  display: flex;
  justify-content: flex-end;
  align-items: center;
  gap: 8px;
}

:global(.knowledge-tag-edit-modal) {
  width: min(520px, 95vw);
}

.tag-edit-modal {
  display: grid;
  gap: 14px;
}

.tag-edit-modal__header {
  display: grid;
  gap: 4px;
}

.tag-edit-modal__header p {
  margin: 0;
}

.tag-edit-modal__field {
  display: grid;
  gap: 6px;
}
</style>
