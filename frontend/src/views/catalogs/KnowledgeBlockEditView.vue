<template>
  <div v-if="loaded" class="stack">
    <CrudHeader
      title="Knowledge Block"
      :dirty="headerDirty"
      :position="positionNumber"
      :total="totalCount"
      :navDisabled="navDisabled"
      :showDelete="!isNew && !sharedReadonly"
      :showDuplicate="!isNew"
      :saving="saving"
      @save="save"
      @cancel="cancelChanges"
      @close="goList"
      @create="createNew"
      @prev="goPrev"
      @next="goNext"
      @delete="remove"
      @duplicate="duplicate"
    />

    <p v-if="loadError" class="error-text">{{ loadError }}</p>
    <KnowledgeBlockReadonlyBanner v-if="sharedReadonly" />

    <fieldset class="stack" :disabled="loading || saving || Boolean(loadError) || sharedReadonly">
      <div v-if="loading" class="loading-float" aria-live="polite">Loading…</div>

      <KnowledgeBlockMainFields
        v-model:name="form.name"
        v-model:version="form.version"
        :form-errors="formErrors"
        :name-error="nameError"
        :version-error="versionError"
        @clear-field="clearField"
      />

      <div class="card stack">
        <KnowledgeBlockTabsNav v-model="blockTab" :files-count="filesTabCount" />

        <KnowledgeBlockVisualEditor
          v-if="blockTab === 'visual'"
          ref="visualEditorRef"
          v-model:content="form.content"
          :content-error="contentError"
          :disabled="visualEditingDisabled"
          @clear-content-error="errors.clearField('content')"
          @edit-source="openCodeAtPosition"
        />

        <KnowledgeBlockCodeEditor
          v-else-if="blockTab === 'code'"
          ref="codeEditorRef"
          v-model:content="form.content"
          :content-error="contentError"
          @clear-content-error="errors.clearField('content')"
        />

        <KnowledgeBlockVariablesSection
          v-else-if="blockTab === 'variables'"
          v-model:variables="form.variables"
        />

        <KnowledgeBlockTagsSection
          v-else-if="blockTab === 'tags'"
          v-model:modal-open="tagModalOpen"
          :attached-tags="attachedTags"
          :attached-tag-ids="attachedTagIds"
          :all-tags="allTags"
          :all-tags-loading="allTagsLoading"
          :all-tags-error="allTagsError"
          :loading="tagBindingsLoading"
          :error="tagBindingsError"
          :dirty="tagsDirty"
          :saving="saving"
          @open-picker="openTagModal"
          @toggle-tag="toggleTag"
          @remove-tag="removeTag"
        />

        <KnowledgeBlockFilesSection
          v-else-if="blockTab === 'files'"
          :attachments="fileAttachments"
          :loading="filesLoading"
          :error="filesError"
          :dirty="filesDirty"
          :saving="saving"
          :shared-readonly="sharedReadonly"
          :action-disabled="filesActionDisabled"
          :is-new="isNew"
          @add-files="handleFilesSelected"
          @remove-file="removeAttachment"
          @set-enabled="toggleAttachmentEnabled"
        />

        <KnowledgeBlockDetailsSection
          v-else
          v-model:image="form.image"
          :name="form.name"
          :is-new="isNew"
          :saving="saving"
          :block-id="numericId"
          :external-id="form.external_id"
          :token-count="form.token_count"
        />
      </div>
    </fieldset>
  </div>

  <p v-else class="muted">Loading…</p>
</template>

<script setup lang="ts">
import { computed, nextTick, ref, toRef, watch } from 'vue';
import { useRoute } from 'vue-router';

import { getApiErrorMessage } from '@/api/client';
import {
  jsonApiCreate,
  jsonApiList,
  toIntId,
  type JsonApiResource,
} from '@/api/jsonApi';
import CrudHeader from '@/components/CrudHeader.vue';
import KnowledgeBlockCodeEditor from '@/features/catalogs/components/knowledge-block/KnowledgeBlockCodeEditor.vue';
import KnowledgeBlockDetailsSection from '@/features/catalogs/components/knowledge-block/KnowledgeBlockDetailsSection.vue';
import KnowledgeBlockFilesSection from '@/features/catalogs/components/knowledge-block/KnowledgeBlockFilesSection.vue';
import KnowledgeBlockMainFields from '@/features/catalogs/components/knowledge-block/KnowledgeBlockMainFields.vue';
import KnowledgeBlockReadonlyBanner from '@/features/catalogs/components/knowledge-block/KnowledgeBlockReadonlyBanner.vue';
import KnowledgeBlockTabsNav from '@/features/catalogs/components/knowledge-block/KnowledgeBlockTabsNav.vue';
import KnowledgeBlockTagsSection from '@/features/catalogs/components/knowledge-block/KnowledgeBlockTagsSection.vue';
import KnowledgeBlockVariablesSection from '@/features/catalogs/components/knowledge-block/KnowledgeBlockVariablesSection.vue';
import KnowledgeBlockVisualEditor from '@/features/catalogs/components/knowledge-block/KnowledgeBlockVisualEditor.vue';
import type { KnowledgeBlockTab } from '@/features/catalogs/components/knowledge-block/types';
import { useLocalTextDraft } from '@/features/app/useLocalTextDraft';
import { useCrudEditor } from '@/features/catalogs/model/useCrudEditor';
import {
  useKnowledgeBlockFileBindingsDraft,
  type KnowledgeBlockFileDraftItem,
} from '@/features/catalogs/model/useKnowledgeBlockFileBindingsDraft';
import { stripKnowledgeBlockComments } from '@/features/catalogs/model/knowledgeBlockMarkdownBlocks';
import { useKnowledgeBlockTagsDraft } from '@/features/catalogs/model/useKnowledgeBlockTagsDraft';
import { useUnsavedChangesGuard } from '@/features/catalogs/model/useUnsavedChangesGuard';
import { parseImageAsset } from '@/features/media/image';
import type { ImageAsset } from '@/types/api';

type KnowledgeBlockForm = {
  name: string;
  version: string;
  content: string;
  image: ImageAsset | null;
  variables: Record<string, string>;
  external_id: string | null;
  token_count: number | null;
  can_edit: boolean;
  shared_incoming: boolean;
  shared_outgoing: boolean;
  created_at: string | null;
  updated_at: string | null;
};

type LinkSpec = {
  basePath: string;
  joinType: string;
  ownerIdAttr: string;
  ownerId: number;
};

const KNOWLEDGE_BLOCK_DOCUMENT_INCLUDE = 'tag_bindings.knowledge_tag';

const route = useRoute();
const routeIdParam = computed(() => route.params.id as string | undefined);
const routeIsNew = computed(() => !routeIdParam.value || routeIdParam.value === 'new');
const defaultTagId = computed(() => toIntId(route.query.defaultTagId as any));
const tagsDraft = useKnowledgeBlockTagsDraft({
  isNew: routeIsNew,
  defaultTagId,
});

const tagModalOpen = tagsDraft.tagModalOpen;
const allTagsLoading = tagsDraft.allTagsLoading;
const allTagsError = tagsDraft.allTagsError;
const allTags = tagsDraft.allTags;
const tagBindingsLoading = tagsDraft.tagBindingsLoading;
const tagBindingsError = tagsDraft.tagBindingsError;
const tagsDirty = tagsDraft.tagsDirty;
const tagBindingsPayload = tagsDraft.tagBindingsPayload;
const attachedTagIds = tagsDraft.attachedTagIds;
const attachedTags = tagsDraft.attachedTags;
const openTagModal = tagsDraft.openTagModal;
const toggleTag = tagsDraft.toggleTag;
const removeTag = tagsDraft.removeTag;

function fromApi(resource: JsonApiResource): Partial<KnowledgeBlockForm> {
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const rawVariables = attrs.variables && typeof attrs.variables === 'object' ? (attrs.variables as Record<string, unknown>) : {};
  const variables: Record<string, string> = {};
  for (const [key, value] of Object.entries(rawVariables)) variables[key] = String(value ?? '');

  return {
    name: String(attrs.name || ''),
    version: String(attrs.version || ''),
    content: String(attrs.content || ''),
    image: parseImageAsset(attrs.image),
    variables,
    external_id: typeof attrs.external_id === 'string' ? attrs.external_id : null,
    token_count: typeof attrs.token_count === 'number' ? attrs.token_count : null,
    can_edit: attrs.can_edit !== false,
    shared_incoming: Boolean(attrs.shared_incoming),
    shared_outgoing: Boolean(attrs.shared_outgoing),
    created_at: typeof attrs.created_at === 'string' ? attrs.created_at : null,
    updated_at: typeof attrs.updated_at === 'string' ? attrs.updated_at : null,
  };
}

const linkSpec = computed<LinkSpec | null>(() => {
  const linkTo = String(route.query.linkTo || '').trim();
  const ownerId = toIntId(route.query.linkId as any);
  if (!ownerId) return null;

  if (linkTo === 'bot') {
    return {
      basePath: '/api/ash/bot-knowledge-blocks',
      joinType: 'bot-knowledge-blocks',
      ownerIdAttr: 'bot_id',
      ownerId,
    };
  }

  if (linkTo === 'llm_configuration' || linkTo === 'llm-configuration') {
    return {
      basePath: '/api/ash/llm-configuration-knowledge-blocks',
      joinType: 'llm-configuration-knowledge-blocks',
      ownerIdAttr: 'llm_configuration_id',
      ownerId,
    };
  }

  if (linkTo === 'chat') {
    return {
      basePath: '/api/ash/chat-knowledge-blocks',
      joinType: 'chat-knowledge-blocks',
      ownerIdAttr: 'chat_id',
      ownerId,
    };
  }

  return null;
});

const linking = ref(false);
const linkedAfterCreate = ref(false);

async function linkToOwner(spec: LinkSpec, blockId: number) {
  if (linking.value) return;
  linking.value = true;

  try {
    const qs = new URLSearchParams();
    qs.set(`filter[${spec.ownerIdAttr}]`, String(spec.ownerId));
    qs.set('sort', 'sequence');
    const payload = await jsonApiList(spec.basePath, qs);
    const sequences = (payload.data || [])
      .map((r) => Number(((r.attributes || {}) as any).sequence ?? 0))
      .filter((n) => Number.isFinite(n));
    const nextSequence = Math.max(-1, ...sequences) + 1;

    await jsonApiCreate(spec.basePath, spec.joinType, {
      [spec.ownerIdAttr]: spec.ownerId,
      knowledge_block_id: blockId,
      enabled: true,
      sequence: nextSequence,
    });

    linkedAfterCreate.value = true;
  } catch (e) {
    console.error(e);
    alert('Failed to link knowledge block.');
  } finally {
    linking.value = false;
  }
}

const editor = useCrudEditor<KnowledgeBlockForm>({
  type: 'knowledge-blocks',
  basePath: '/api/ash/knowledge-blocks',
  indexPath: '/catalogs/knowledge-blocks',
  editPath: (id) => `/catalogs/knowledge-blocks/${id}`,
  defaultForm: () => ({
    name: '',
    version: '',
    content: '',
    image: null,
    variables: {},
    external_id: null,
    token_count: null,
    can_edit: true,
    shared_incoming: false,
    shared_outgoing: false,
    created_at: null,
    updated_at: null,
  }),
  fromApi,
  toAttributes: (form) => ({
    name: form.name,
    version: form.version,
    content: form.content,
    variables: form.variables || {},
    ...(tagBindingsPayload.value === undefined ? {} : { tag_bindings: tagBindingsPayload.value }),
  }),
  normalizeForDirty: (form) => ({
    name: form.name,
    version: form.version,
    content: form.content,
    variables: form.variables,
    can_edit: form.can_edit,
    shared_incoming: form.shared_incoming,
    shared_outgoing: form.shared_outgoing,
  }),
  duplicatePath: (id) => `/api/ash/knowledge-blocks/${id}/duplicate`,
  preserveQueryKeys: ['defaultTagId', 'linkTo', 'linkId'],
  documentQuery: () => {
    const params = new URLSearchParams();
    params.set('include', KNOWLEDGE_BLOCK_DOCUMENT_INCLUDE);
    return params;
  },
  onDocument: (payload) => {
    tagsDraft.applyDocument(payload);
  },
});

const form = editor.form;
const contentDraftValue = toRef(form, 'content');
const errors = editor.errors;
const formErrors = computed(() => errors.formErrors.value);
const nameError = computed(() => (errors.hasField('name') ? errors.messageFor('name') : null));
const versionError = computed(() => (errors.hasField('version') ? errors.messageFor('version') : null));
const contentError = computed(() => (errors.hasField('content') ? errors.messageFor('content') : null));
const isNew = editor.isNew;
const loaded = editor.loaded;
const loading = editor.loading;
const loadError = editor.loadError;
const numericId = editor.numericId;
const sharedReadonly = computed(() => !isNew.value && form.can_edit === false);

const fileBindings = useKnowledgeBlockFileBindingsDraft();
const fileAttachments = fileBindings.draft;
const filesLoading = fileBindings.loading;
const filesError = fileBindings.error;
const filesDirty = fileBindings.dirty;
const suppressFilesAutoLoad = ref(false);

const totalCount = editor.totalCount;
const positionNumber = editor.positionNumber;
const navDisabled = editor.navDisabled;
const goPrev = editor.goPrev;
const goNext = editor.goNext;
const blockTab = ref<KnowledgeBlockTab>('visual');
const initializedTabForId = ref<string | null>(null);
const codeEditorRef = ref<InstanceType<typeof KnowledgeBlockCodeEditor> | null>(null);
const visualEditorRef = ref<InstanceType<typeof KnowledgeBlockVisualEditor> | null>(null);

const filesTabCount = computed(() => fileAttachments.value.length);
const saving = computed(() => editor.saving.value || linking.value || fileBindings.syncing.value);
const filesActionDisabled = computed(
  () =>
    saving.value ||
    sharedReadonly.value ||
    filesLoading.value ||
    (!isNew.value && !fileBindings.loaded.value)
);
const visualEditingDisabled = computed(
  () => loading.value || saving.value || Boolean(loadError.value) || sharedReadonly.value
);

function getInitialBlockTab() {
  return isNew.value || !stripKnowledgeBlockComments(form.content).trim() ? 'code' : 'visual';
}

watch(
  () => editor.idParam.value,
  () => {
    initializedTabForId.value = null;
    tagModalOpen.value = false;
    linkedAfterCreate.value = false;
    visualEditorRef.value?.reset();
    codeEditorRef.value?.resetScroll();
  }
);

watch(
  () => [editor.idParam.value, loaded.value, loading.value] as const,
  ([id, isLoaded, isLoading]) => {
    if (!isLoaded || isLoading) return;
    const currentId = id || 'new';
    if (initializedTabForId.value === currentId) return;
    blockTab.value = getInitialBlockTab();
    initializedTabForId.value = currentId;
  },
  { immediate: true }
);

watch(blockTab, (tab) => {
  if (tab !== 'visual') visualEditorRef.value?.reset();
});

const knowledgeBlockContentDraftStorageKey = computed(() => {
  if (isNew.value) {
    const linkTo = String(route.query.linkTo || '').trim();
    const linkId = String(route.query.linkId || '').trim();
    const tagId = defaultTagId.value ? String(defaultTagId.value) : '';
    return `ic.draft.knowledge_block.content.new.${linkTo}.${linkId}.${tagId}`;
  }

  const blockId = editor.numericId.value;
  return blockId ? `ic.draft.knowledge_block.content.${blockId}` : null;
});
const knowledgeBlockContentDraftRevision = computed(() => {
  if (isNew.value) {
    const linkTo = String(route.query.linkTo || '').trim();
    const linkId = String(route.query.linkId || '').trim();
    const tagId = defaultTagId.value ? String(defaultTagId.value) : '';
    return `new:${linkTo}:${linkId}:${tagId}`;
  }

  const blockId = editor.numericId.value;
  if (!blockId) return null;
  return form.updated_at || form.created_at || String(blockId);
});
const knowledgeBlockContentDraft = useLocalTextDraft({
  storageKey: knowledgeBlockContentDraftStorageKey,
  revision: knowledgeBlockContentDraftRevision,
  value: contentDraftValue,
  enabled: computed(() => loaded.value && !loading.value && !saving.value && !sharedReadonly.value),
  isDraft: computed(() => form.content !== editor.base.value.content && !sharedReadonly.value),
});
const dirty = computed(() => editor.dirty.value || tagsDirty.value || filesDirty.value);
const guardDirty = computed(() => dirty.value && !saving.value);
const headerDirty = computed(() => dirty.value && !loading.value && !loadError.value);
useUnsavedChangesGuard(guardDirty);

function clearField(field: 'name' | 'version') {
  errors.clearField(field);
}

async function openCodeAtPosition(position: number) {
  blockTab.value = 'code';
  await nextTick();
  await codeEditorRef.value?.focusAtPosition(position);
}

const save = async () => {
  if (saving.value) return;
  const contentDraftKeyBeforeSave = knowledgeBlockContentDraftStorageKey.value;
  const spec = linkSpec.value;
  const wasNew = editor.isNew.value;
  const shouldLinkOwner = wasNew && Boolean(spec) && !linkedAfterCreate.value;
  const shouldSyncFiles = fileBindings.loaded.value && fileBindings.dirty.value && !sharedReadonly.value;

  if (shouldSyncFiles) suppressFilesAutoLoad.value = true;

  const saved = await editor.save();
  if (!saved) {
    suppressFilesAutoLoad.value = false;
    return;
  }

  knowledgeBlockContentDraft.clear(contentDraftKeyBeforeSave);

  if (shouldLinkOwner && spec) {
    const newId = editor.numericId.value;
    if (newId) await linkToOwner(spec, newId);
  }

  try {
    if (shouldSyncFiles) {
      const blockId = editor.numericId.value;
      if (!blockId) throw new Error('Saved knowledge block id is missing.');
      await fileBindings.sync(blockId);
    }
  } catch (error) {
    console.error(error);
    blockTab.value = 'files';
    alert(getApiErrorMessage(error, 'Failed to save file changes.'));
  } finally {
    suppressFilesAutoLoad.value = false;
  }
};

const cancelChanges = () => {
  visualEditorRef.value?.reset();
  codeEditorRef.value?.resetScroll();
  editor.reset();
  tagsDraft.reset();
  fileBindings.reset();
};
const remove = editor.remove;
const duplicate = editor.duplicate;
const createNew = editor.createNew;
const goList = editor.goList;

watch(
  () => [editor.numericId.value, loaded.value, isNew.value] as const,
  ([blockId, isLoaded, newRecord]) => {
    if (!isLoaded) return;
    if (suppressFilesAutoLoad.value) return;

    if (newRecord || !blockId) {
      fileBindings.hydrate([]);
      return;
    }

    void fileBindings.load(blockId);
  },
  { immediate: true }
);

const handleFilesSelected = (files: File[]) => {
  if (!files.length || sharedReadonly.value || filesActionDisabled.value) return;

  fileBindings.addFiles(files);
};

const removeAttachment = (attachment: KnowledgeBlockFileDraftItem) => {
  if (sharedReadonly.value) return;
  fileBindings.remove(attachment.id);
};

function toggleAttachmentEnabled(attachment: KnowledgeBlockFileDraftItem, enabled: boolean) {
  if (sharedReadonly.value) return;

  fileBindings.setEnabled(attachment.id, enabled);
}
</script>
