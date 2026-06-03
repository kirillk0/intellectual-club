<template>
  <section class="card stack llm-config-tags-panel">
    <div class="llm-config-tags-panel__header">
      <strong>{{ title }}</strong>
      <div class="llm-config-tags-panel__header-actions">
        <button
          type="button"
          class="icon-button llm-config-tags-panel__add-button"
          :disabled="mutationLoading"
          aria-label="Add tag"
          title="Add tag"
          @click="startCreate"
        >
          +
        </button>
        <button type="button" class="link" :disabled="!hasActiveFilter || mutationLoading" @click="emit('clear-filter')">
          Clear
        </button>
        <slot name="header-extra"></slot>
      </div>
    </div>

    <form v-if="editorMode" class="llm-config-tags-panel__editor" @submit.prevent="submitEditor">
      <div class="llm-config-tags-panel__editor-title">{{ editorTitle }}</div>
      <p v-if="editorContext" class="muted llm-config-tags-panel__editor-context">{{ editorContext }}</p>

      <label class="llm-config-tags-panel__editor-field">
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

      <div class="llm-config-tags-panel__editor-actions">
        <button type="button" :disabled="mutationLoading" @click="cancelEditor">Cancel</button>
        <button type="submit" class="primary" :disabled="submitDisabled">{{ editorSubmitLabel }}</button>
      </div>
    </form>

    <p v-if="tagsLoading" class="muted">Loading…</p>
    <p v-else-if="tagsError" class="error-text">{{ tagsError }}</p>
    <LlmConfigurationTagsList
      v-else
      :tags="tags"
      :selectedId="selectedId"
      :showNoTagsOption="showNoTagsOption"
      :noTagsSelected="noTagsSelected"
      :noTagsLabel="noTagsLabel"
      :showItemActions="true"
      :actionsDisabled="mutationLoading"
      @select="emit('select', $event)"
      @select-no-tags="emit('select-no-tags')"
      @edit="openEditModal"
      @delete="deleteTag"
    />

    <p v-if="!tagsLoading && !tagsError && !tags.length" class="muted">No tags.</p>
  </section>

  <ModalWindow
    :open="editModalOpen"
    modal-class="llm-config-tag-edit-modal"
    aria-label="Edit tag"
    :cancel-disabled="mutationLoading"
    @cancel="cancelEditModal"
  >
    <form class="tag-edit-modal" @submit.prevent="submitEditModal">
      <div class="tag-edit-modal__header">
        <strong>Edit tag</strong>
        <p v-if="currentEditTag?.name" class="muted">{{ currentEditTag.name }}</p>
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
import LlmConfigurationTagsList, { type LlmConfigurationTagListItem } from '@/components/LlmConfigurationTagsList.vue';
import ModalWindow from '@/components/ModalWindow.vue';
import {
  fieldErrorsFromJsonApiErrors,
  formErrorsFromJsonApiErrors,
  getJsonApiErrors,
  jsonApiCreate,
  jsonApiDelete,
  jsonApiList,
  jsonApiUpdate,
  toIntId,
  type JsonApiResource,
} from '@/api/jsonApi';

type EditorMode = 'create';

const props = withDefaults(
  defineProps<{
    title?: string;
    selectedId?: number | null;
    noTagsSelected?: boolean;
    hasActiveFilter?: boolean;
    showNoTagsOption?: boolean;
    noTagsLabel?: string;
  }>(),
  {
    title: 'Tags',
    selectedId: null,
    noTagsSelected: false,
    hasActiveFilter: false,
    showNoTagsOption: true,
    noTagsLabel: 'No tags',
  }
);

const emit = defineEmits<{
  (e: 'select', id: number): void;
  (e: 'select-no-tags'): void;
  (e: 'clear-filter'): void;
  (e: 'changed'): void;
}>();

const tagsLoading = ref(false);
const tagsError = ref<string | null>(null);
const tags = ref<LlmConfigurationTagListItem[]>([]);
const mutationLoading = ref(false);

const editorMode = ref<EditorMode | null>(null);
const editorTagId = ref<number | null>(null);
const editorName = ref('');
const editorError = ref<string | null>(null);
const editorInputRef = ref<HTMLInputElement | null>(null);
const editModalOpen = ref(false);
const editModalTagId = ref<number | null>(null);
const editModalName = ref('');
const editModalError = ref<string | null>(null);
const editModalInputRef = ref<HTMLInputElement | null>(null);

function parseTagRow(resource: JsonApiResource): LlmConfigurationTagListItem | null {
  const id = toIntId(resource.id);
  if (!id) return null;

  const attrs = (resource.attributes || {}) as Record<string, unknown>;

  return {
    id,
    name: String(attrs.name || '').trim(),
  };
}

function describeMutationError(error: unknown, fallbackMessage: string) {
  const jsonApiErrors = getJsonApiErrors(error);
  if (jsonApiErrors?.length) {
    const fieldErrors = fieldErrorsFromJsonApiErrors(jsonApiErrors);
    const nameErrors = fieldErrors.name;
    if (nameErrors?.length) return nameErrors.join(' ');

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

const editorTitle = computed(() => 'New tag');
const editorContext = computed(() => currentEditorTag.value?.name || '');
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
  editModalError.value = null;
}

function cancelEditor() {
  resetEditor();
}

function cancelEditModal() {
  if (mutationLoading.value) return;
  resetEditModal();
}

function startCreate() {
  editorMode.value = 'create';
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
  editModalError.value = null;
  editModalOpen.value = true;
  void focusEditModalInput();
}

async function loadTags() {
  tagsLoading.value = true;
  tagsError.value = null;

  try {
    const params = new URLSearchParams();
    params.set('sort', 'name');
    params.set('editable_only', 'true');
    params.set('fields[llm-configuration-tags]', 'name');
    const payload = await jsonApiList('/api/ash/llm-configuration-tags', params);
    tags.value = (payload.data || []).map(parseTagRow).filter((tag): tag is LlmConfigurationTagListItem => Boolean(tag));
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
    await jsonApiCreate('/api/ash/llm-configuration-tags', 'llm-configuration-tags', { name });

    resetEditor();
    await loadTags();
    emit('changed');
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

  mutationLoading.value = true;
  editModalError.value = null;
  tagsError.value = null;

  try {
    await jsonApiUpdate('/api/ash/llm-configuration-tags', 'llm-configuration-tags', tag.id, { name });

    resetEditModal();
    await loadTags();
    emit('changed');
  } catch (error) {
    console.error(error);
    editModalError.value = describeMutationError(error, 'Failed to save tag.');
  } finally {
    mutationLoading.value = false;
  }
}

async function deleteTag(tagId: number) {
  const tag = tags.value.find((row) => row.id === tagId);
  const label = tag?.name || `Tag #${tagId}`;
  if (!window.confirm(`Delete tag "${label}"?`)) return;

  mutationLoading.value = true;
  editorError.value = null;
  tagsError.value = null;

  try {
    const shouldClearFilter = props.selectedId === tagId;
    await jsonApiDelete('/api/ash/llm-configuration-tags', tagId);

    if (editorTagId.value === tagId) resetEditor();
    if (editModalTagId.value === tagId) resetEditModal();

    await loadTags();
    emit('changed');

    if (shouldClearFilter) emit('clear-filter');
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
.llm-config-tags-panel {
  gap: 10px;
}

.llm-config-tags-panel__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.llm-config-tags-panel__header-actions {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  flex-wrap: nowrap;
}

.llm-config-tags-panel__add-button {
  width: 30px;
  height: 30px;
  font-size: 20px;
}

.llm-config-tags-panel__editor {
  display: grid;
  gap: 8px;
  padding: 10px;
  border: 1px solid var(--color-border);
  border-radius: 12px;
  background: var(--color-surface-subtle);
}

.llm-config-tags-panel__editor-title {
  font-weight: 700;
}

.llm-config-tags-panel__editor-context {
  margin: 0;
}

.llm-config-tags-panel__editor-field {
  display: grid;
  gap: 6px;
}

.llm-config-tags-panel__editor-actions {
  display: flex;
  justify-content: flex-end;
  align-items: center;
  gap: 8px;
}

:global(.llm-config-tag-edit-modal) {
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
