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
    <div v-if="sharedReadonly" class="card share-banner">
      <strong>Shared with you.</strong> This knowledge block is read-only. Duplicate it to create an editable copy.
    </div>

    <fieldset class="stack" :disabled="loading || saving || Boolean(loadError) || sharedReadonly">
      <div v-if="loading" class="loading-float" aria-live="polite">Loading…</div>
      <div class="card stack">
        <div v-if="errors.formErrors.length" class="error-text">{{ errors.formErrors.join(' ') }}</div>

        <label :class="{ 'field-error': errors.hasField('name') }">
          Name
          <input v-model="form.name" class="full" @input="errors.clearField('name')" />
          <div v-if="errors.hasField('name')" class="error-text">{{ errors.messageFor('name') }}</div>
        </label>

        <label :class="{ 'field-error': errors.hasField('version') }">
          Version
          <input v-model="form.version" class="full" placeholder="Optional" @input="errors.clearField('version')" />
          <div v-if="errors.hasField('version')" class="error-text">{{ errors.messageFor('version') }}</div>
        </label>

        <label :class="{ 'field-error': errors.hasField('type') }">
          Type
          <select v-model="form.type" class="full" @change="errors.clearField('type')">
            <option value="rules">rules</option>
            <option value="lore">lore</option>
            <option value="character">character</option>
            <option value="scenario">scenario</option>
            <option value="style_guide">style_guide</option>
            <option value="other">other</option>
          </select>
          <div v-if="errors.hasField('type')" class="error-text">{{ errors.messageFor('type') }}</div>
        </label>
      </div>

      <div class="card stack">
        <div class="flex" style="justify-content: space-between; align-items: center; gap: 10px">
          <div class="stack" style="gap: 2px">
            <strong>Image</strong>
            <div class="muted" style="font-size: 0.85rem">Used in selectors and catalogs.</div>
          </div>
          <div class="flex" style="gap: 8px">
            <button type="button" :disabled="isNew || saving" @click="triggerImageUpload">Upload</button>
            <button type="button" class="danger" :disabled="!form.image || saving" @click="removeImage">
              Remove
            </button>
          </div>
        </div>

        <input ref="imageInput" type="file" accept="image/*" style="display: none" @change="handleImageSelected" />

        <div v-if="form.image" class="row" style="align-items: center; gap: 12px">
          <ImageThumbnail :image="form.image" :label="form.name" :size="56" />
          <div class="stack" style="gap: 2px; min-width: 0">
            <div style="font-weight: 600; overflow: hidden; text-overflow: ellipsis">{{ form.image.filename }}</div>
            <div class="muted" style="font-size: 0.85rem">{{ form.image.mime_type }}</div>
            <div class="muted" style="font-size: 0.85rem">{{ formatBytes(form.image.size_bytes) }}</div>
          </div>
        </div>
        <div v-else class="muted">No image uploaded.</div>
        <div v-if="isNew" class="muted" style="font-size: 0.85rem">Save the block before uploading an image.</div>
      </div>

      <div class="card stack">
        <div class="tabs">
          <button class="tab" :class="{ active: blockTab === 'content' }" type="button" @click="blockTab = 'content'">
            Content
          </button>
          <button
            class="tab"
            :class="{ active: blockTab === 'variables' }"
            type="button"
            @click="blockTab = 'variables'"
          >
            Variables
          </button>
          <button class="tab" :class="{ active: blockTab === 'tags' }" type="button" @click="blockTab = 'tags'">Tags</button>
          <button
            class="tab"
            :class="{ active: blockTab === 'details' }"
            type="button"
            @click="blockTab = 'details'"
          >
            Details
          </button>
        </div>

        <div v-if="blockTab === 'content'" class="stack">
          <label>
            Content
            <div
              :class="[
                'knowledge-block-content-editor',
                errors.hasField('content') && 'knowledge-block-content-editor--error',
              ]"
            >
              <pre class="knowledge-block-content-editor__mirror" aria-hidden="true"><code
                :style="contentMirrorStyle"
                v-html="contentHighlightHtml"
              ></code></pre>
              <textarea
                ref="contentTextareaRef"
                v-model="form.content"
                :class="[
                  'full',
                  'knowledge-block-content-editor__textarea',
                  !form.content && 'knowledge-block-content-editor__textarea--empty',
                ]"
                rows="14"
                placeholder="Write the knowledge block content..."
                spellcheck="false"
                @input="errors.clearField('content')"
                @scroll="syncContentEditorScroll"
              ></textarea>
            </div>
            <div class="muted knowledge-block-content-editor__hint">
              Lines starting with <code>//// </code> are treated as comments and removed from the compiled prompt.
            </div>
            <div v-if="errors.hasField('content')" class="error-text">{{ errors.messageFor('content') }}</div>
          </label>
        </div>

        <div v-else-if="blockTab === 'variables'" class="stack">
          <strong>Variables</strong>
          <VariablesTable :modelValue="variablesRows" @update:modelValue="setVariablesRows" />
          <div class="muted">
            Variables are exposed to prompts as <code v-text="'{{key}}'"></code>.
          </div>
        </div>

        <div v-else-if="blockTab === 'tags'" class="stack">
          <div style="display: flex; align-items: center; justify-content: space-between; gap: 10px">
            <strong>Tags</strong>
            <button type="button" @click="openTagModal" :disabled="saving">Add tag</button>
          </div>

          <p v-if="tagBindingsLoading" class="muted">Loading…</p>
          <p v-else-if="tagBindingsError" class="error-text">{{ tagBindingsError }}</p>

          <div v-else class="list">
            <div v-for="t in attachedTags" :key="t.id" class="row" style="justify-content: space-between; gap: 10px">
              <div style="min-width: 0">
                <div style="font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">
                  {{ t.full_name || t.name }}
                </div>
              </div>
              <button type="button" :disabled="saving" @click="removeTag(t.id)">Remove</button>
            </div>

            <p v-if="!attachedTags.length" class="muted">No tags.</p>
          </div>

          <p v-if="tagsDirty" class="muted">Tag changes will be saved when you save the block.</p>
        </div>

        <div v-else class="stack">
          <div style="font-weight: 700">Details</div>
          <div class="muted">External ID</div>
          <div style="font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px">
            {{ form.external_id || '(generated on save)' }}
          </div>
          <div class="muted" style="margin-top: 6px">Token estimate</div>
          <div>{{ form.token_count ?? '(calculated on save)' }}</div>
        </div>
      </div>
    </fieldset>

    <KnowledgeTagsPickerModal
      v-model:open="tagModalOpen"
      :tags="allTags"
      :selectedTagIds="attachedTagIds"
      :loading="allTagsLoading"
      :error="allTagsError"
      title="Add tag"
      @select="toggleTag"
    />
  </div>

  <p v-else class="muted">Loading…</p>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import CrudHeader from '@/components/CrudHeader.vue';
import ImageThumbnail from '@/components/ImageThumbnail.vue';
import KnowledgeTagsPickerModal from '@/components/KnowledgeTagsPickerModal.vue';
import VariablesTable from '@/components/VariablesTable.vue';
import { deleteKnowledgeBlockImage, uploadKnowledgeBlockImage } from '@/api/images';
import { useCrudEditor } from '@/features/catalogs/model/useCrudEditor';
import { useUnsavedChangesGuard } from '@/features/catalogs/model/useUnsavedChangesGuard';
import { parseImageAsset } from '@/features/media/image';
import {
  createJsonApiIncludedIndex,
  jsonApiCreate,
  jsonApiGet,
  jsonApiList,
  relatedResource,
  relatedResources,
  relationshipId,
  toIntId,
  type JsonApiResource,
  type JsonApiSingleResponse,
} from '@/api/jsonApi';
import type { ImageAsset } from '@/types/api';

type KnowledgeBlockForm = {
  name: string;
  version: string;
  type: string;
  content: string;
  image: ImageAsset | null;
  variables: Record<string, string>;
  external_id: string | null;
  token_count: number | null;
  can_edit: boolean;
  shared_incoming: boolean;
  shared_outgoing: boolean;
};

function fromApi(resource: JsonApiResource): Partial<KnowledgeBlockForm> {
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const rawVariables = attrs.variables && typeof attrs.variables === 'object' ? (attrs.variables as Record<string, unknown>) : {};
  const variables: Record<string, string> = {};
  for (const [key, value] of Object.entries(rawVariables)) variables[key] = String(value ?? '');

  return {
    name: String(attrs.name || ''),
    version: String(attrs.version || ''),
    type: String(attrs.type || 'rules'),
    content: String(attrs.content || ''),
    image: parseImageAsset(attrs.image),
    variables,
    external_id: typeof attrs.external_id === 'string' ? attrs.external_id : null,
    token_count: typeof attrs.token_count === 'number' ? attrs.token_count : null,
    can_edit: attrs.can_edit !== false,
    shared_incoming: Boolean(attrs.shared_incoming),
    shared_outgoing: Boolean(attrs.shared_outgoing),
  };
}

type LinkSpec = {
  basePath: string;
  joinType: string;
  ownerIdAttr: string;
  ownerId: number;
};

const KNOWLEDGE_BLOCK_DOCUMENT_INCLUDE = 'tag_bindings.knowledge_tag';

const route = useRoute();

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
    type: 'rules',
    content: '',
    image: null,
    variables: {},
    external_id: null,
    token_count: null,
    can_edit: true,
    shared_incoming: false,
    shared_outgoing: false,
  }),
  fromApi,
  toAttributes: (form) => ({
    name: form.name,
    version: form.version,
    type: form.type,
    content: form.content,
    variables: form.variables || {},
    ...(tagBindingsPayload.value === undefined ? {} : { tag_bindings: tagBindingsPayload.value }),
  }),
  normalizeForDirty: (form) => ({
    name: form.name,
    version: form.version,
    type: form.type,
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
    applyKnowledgeBlockDocument(payload);
  },
});

const form = editor.form;
const errors = editor.errors;
const isNew = editor.isNew;
const loaded = editor.loaded;
const loading = editor.loading;
const loadError = editor.loadError;
const sharedReadonly = computed(() => !isNew.value && form.can_edit === false);

const totalCount = editor.totalCount;
const positionNumber = editor.positionNumber;
const navDisabled = editor.navDisabled;
const goPrev = editor.goPrev;
const goNext = editor.goNext;
const blockTab = ref<'content' | 'variables' | 'tags' | 'details'>('content');

type KnowledgeTagRow = {
  id: number;
  name: string;
  full_name: string;
  parent_id: number | null;
};

type TagBinding = {
  id: number;
  tagId: number;
};

type TagBindingPayloadItem = {
  id?: number;
  knowledge_tag_id: number;
};

const tagModalOpen = ref(false);
const allTagsLoading = ref(false);
const allTagsError = ref<string | null>(null);
const allTags = ref<KnowledgeTagRow[]>([]);

watch(
  () => editor.idParam.value,
  () => {
    tagModalOpen.value = false;
    linkedAfterCreate.value = false;
    contentScrollTop.value = 0;
    contentScrollLeft.value = 0;
    if (contentTextareaRef.value) {
      contentTextareaRef.value.scrollTop = 0;
      contentTextareaRef.value.scrollLeft = 0;
    }
  }
);

const tagBindingsLoading = ref(false);
const tagBindingsError = ref<string | null>(null);
const originalTagBindings = ref<TagBinding[]>([]);
const draftTagBindings = ref<TagBinding[]>([]);
const includedTags = ref<KnowledgeTagRow[]>([]);

const defaultTagId = computed(() => toIntId(route.query.defaultTagId as any));

let tempTagBindingId = -1;

watch(
  () => isNew.value,
  (value) => {
    if (!value) return;
    tempTagBindingId = -1;
    originalTagBindings.value = [];
    draftTagBindings.value = [];
    includedTags.value = [];
    allTagsError.value = null;
    tagBindingsError.value = null;
  },
  { immediate: true }
);

watch(
  () => [isNew.value, defaultTagId.value],
  ([newRecord, tagId]) => {
    if (!newRecord) return;
    if (!tagId) return;
    if (originalTagBindings.value.length === 0 && draftTagBindings.value.length === 0) {
      const binding = { id: tempTagBindingId--, tagId };
      originalTagBindings.value = [binding];
      draftTagBindings.value = [binding];
    }
  },
  { immediate: true }
);

function stableIds(ids: number[]) {
  return Array.from(new Set(ids || [])).sort((a, b) => a - b);
}

const tagsDirty = computed(() => {
  const base = stableIds(originalTagBindings.value.map((b) => b.tagId));
  const current = stableIds(draftTagBindings.value.map((b) => b.tagId));
  return JSON.stringify(base) !== JSON.stringify(current);
});

const tagBindingsPayload = computed<TagBindingPayloadItem[] | undefined>(() => {
  const items = (draftTagBindings.value || []).map((b) => ({
    ...(b.id > 0 ? { id: b.id } : {}),
    knowledge_tag_id: b.tagId,
  }));

  if (isNew.value) return items;
  if (!tagsDirty.value) return undefined;
  return items;
});

const tagById = computed(() => {
  const map = new Map<number, KnowledgeTagRow>();
  for (const t of includedTags.value || []) map.set(t.id, t);
  for (const t of allTags.value || []) map.set(t.id, t);
  return map;
});

function mergeKnownTags(tags: KnowledgeTagRow[]) {
  const byId = new Map<number, KnowledgeTagRow>();
  for (const tag of includedTags.value || []) byId.set(tag.id, tag);
  for (const tag of allTags.value || []) byId.set(tag.id, tag);
  for (const tag of tags || []) byId.set(tag.id, tag);
  allTags.value = Array.from(byId.values()).sort((a, b) => {
    const left = a.full_name || a.name;
    const right = b.full_name || b.name;
    return left.localeCompare(right) || a.id - b.id;
  });
}

const attachedTagIds = computed(() => {
  return stableIds(draftTagBindings.value.map((b) => b.tagId));
});

const attachedTags = computed(() => {
  const ids = draftTagBindings.value.map((b) => b.tagId);
  const uniqueInOrder: number[] = [];
  const seen = new Set<number>();
  for (const id of ids) {
    if (seen.has(id)) continue;
    seen.add(id);
    uniqueInOrder.push(id);
  }

  return uniqueInOrder.map((id) => tagById.value.get(id) || { id, name: `Tag #${id}`, full_name: '', parent_id: null });
});

const saving = computed(() => editor.saving.value || linking.value);
const dirty = computed(() => editor.dirty.value || tagsDirty.value);
const guardDirty = computed(() => dirty.value && !saving.value);
const headerDirty = computed(() => dirty.value && !loading.value && !loadError.value);
useUnsavedChangesGuard(guardDirty);

const COMMENT_PREFIX = '//// ';
const contentTextareaRef = ref<HTMLTextAreaElement | null>(null);
const contentScrollTop = ref(0);
const contentScrollLeft = ref(0);

function escapeHtml(value: string) {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

const contentHighlightHtml = computed(() => {
  const text = String(form.content || '');
  if (text === '') return '&nbsp;';

  const highlighted = text
    .split('\n')
    .map((line) => {
      const escaped = escapeHtml(line) || '&nbsp;';
      return line.startsWith(COMMENT_PREFIX)
        ? `<span class="knowledge-block-content-editor__comment">${escaped}</span>`
        : `<span class="knowledge-block-content-editor__plain">${escaped}</span>`;
    })
    .join('\n');

  return text.endsWith('\n') ? `${highlighted}\n&nbsp;` : highlighted;
});

const contentMirrorStyle = computed(() => ({
  transform: `translate(${-contentScrollLeft.value}px, ${-contentScrollTop.value}px)`,
}));

function syncContentEditorScroll(event: Event) {
  const target = event.target as HTMLTextAreaElement | null;
  if (!target) return;
  contentScrollTop.value = target.scrollTop;
  contentScrollLeft.value = target.scrollLeft;
}

type VarRow = { key: string; value: string };

const mapToVarRows = (vars: Record<string, unknown> | null | undefined): VarRow[] => {
  return Object.entries(vars || {})
    .map(([key, value]) => ({ key: String(key || ''), value: String(value ?? '') }))
    .sort((a, b) => a.key.localeCompare(b.key));
};

const varRowsToMap = (rows: VarRow[] | null | undefined): Record<string, string> => {
  const next: Record<string, string> = {};
  for (const row of rows || []) {
    const key = String(row.key || '').trim();
    if (!key) continue;
    next[key] = String(row.value ?? '');
  }
  return next;
};

const stableVarMap = (vars: Record<string, string>) => JSON.stringify(Object.entries(vars).sort(([a], [b]) => a.localeCompare(b)));

const variablesRows = ref<VarRow[]>([]);

watch(
  () => form.variables,
  (value) => {
    const incoming = varRowsToMap(mapToVarRows((value || {}) as Record<string, unknown>));
    const current = varRowsToMap(variablesRows.value);
    if (stableVarMap(incoming) === stableVarMap(current)) return;
    variablesRows.value = mapToVarRows((value || {}) as Record<string, unknown>);
  },
  { immediate: true, deep: true }
);

const setVariablesRows = (rows: VarRow[]) => {
  variablesRows.value = (rows || []).map((row) => ({ key: String(row.key || ''), value: String(row.value ?? '') }));
  form.variables = varRowsToMap(variablesRows.value);
};

function parseTagRow(resource: JsonApiResource): KnowledgeTagRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const parentId =
    (typeof attrs.parent_id === 'number' ? attrs.parent_id : toIntId(attrs.parent_id as any)) ??
    relationshipId(resource, 'parent');

  return {
    id,
    name: String(attrs.name || '').trim(),
    full_name: String(attrs.full_name || '').trim(),
    parent_id: parentId ?? null,
  };
}

function parseTagBinding(resource: JsonApiResource): TagBinding | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const tagId =
    relationshipId(resource, 'knowledge_tag') ?? toIntId(attrs.knowledge_tag_id as any);
  if (!tagId) return null;

  return { id, tagId };
}

function applyKnowledgeBlockDocument(payload: JsonApiSingleResponse) {
  const includedIndex = createJsonApiIncludedIndex(payload.included);
  const root = payload.data;
  const bindingResources = relatedResources(root, 'tag_bindings', includedIndex);

  originalTagBindings.value = bindingResources.map(parseTagBinding).filter((b): b is TagBinding => Boolean(b));
  draftTagBindings.value = originalTagBindings.value.map((binding) => ({ ...binding }));
  const documentTags = bindingResources
    .map((resource) => parseTagRow(relatedResource(resource, 'knowledge_tag', includedIndex)))
    .filter((tag): tag is KnowledgeTagRow => Boolean(tag));
  includedTags.value = documentTags;
  mergeKnownTags(documentTags);
  tempTagBindingId = -1;
  tagBindingsLoading.value = false;
  tagBindingsError.value = null;
}

async function ensureTagsLoaded(tagIds: number[]) {
  const missingIds = stableIds(tagIds).filter((id) => id > 0 && !tagById.value.has(id));
  if (!missingIds.length) return;

  const loadedTags: KnowledgeTagRow[] = [];

  await Promise.all(
    missingIds.map(async (tagId) => {
      try {
        const payload = await jsonApiGet(`/api/ash/knowledge-tags/${tagId}`);
        const tag = parseTagRow(payload.data);
        if (tag) loadedTags.push(tag);
      } catch (error) {
        console.warn(`Failed to load knowledge tag ${tagId}`, error);
      }
    })
  );

  if (loadedTags.length) mergeKnownTags(loadedTags);
}

async function loadAllTags() {
  if (allTagsLoading.value) return;
  allTagsLoading.value = true;
  allTagsError.value = null;

  try {
    const params = new URLSearchParams();
    params.set('sort', 'full_name');
    const payload = await jsonApiList('/api/ash/knowledge-tags', params);
    allTags.value = (payload.data || []).map(parseTagRow).filter((t): t is KnowledgeTagRow => Boolean(t));
  } catch (e) {
    console.error(e);
    const message = e instanceof Error ? e.message : 'Failed to load tags.';
    if (message.startsWith('HTTP 403') || message.startsWith('HTTP 401')) {
      allTags.value = [];
      allTagsError.value = null;
    } else {
      allTagsError.value = message;
    }
  } finally {
    allTagsLoading.value = false;
  }
}

watch(
  () => attachedTagIds.value,
  (tagIds) => {
    if (!tagIds.length) return;
    void ensureTagsLoaded(tagIds);
  },
  { immediate: true }
);

function openTagModal() {
  tagModalOpen.value = true;
  if (!allTagsLoading.value && !allTags.value.length) void loadAllTags();
}

function addTag(tagId: number) {
  if (!tagId) return;
  if (attachedTagIds.value.includes(tagId)) return;

  const original = originalTagBindings.value.find((b) => b.tagId === tagId);
  if (original) {
    draftTagBindings.value = [...draftTagBindings.value, { ...original }];
    return;
  }

  draftTagBindings.value = [...draftTagBindings.value, { id: tempTagBindingId--, tagId }];
}

function removeTag(tagId: number) {
  if (!tagId) return;
  draftTagBindings.value = draftTagBindings.value.filter((b) => b.tagId !== tagId);
}

function toggleTag(tagId: number) {
  if (!tagId) return;
  if (attachedTagIds.value.includes(tagId)) removeTag(tagId);
  else addTag(tagId);
}

const save = async () => {
  const spec = linkSpec.value;
  const wasNew = editor.isNew.value;
  const shouldLinkOwner = wasNew && Boolean(spec) && !linkedAfterCreate.value;
  await editor.save();

  if (shouldLinkOwner && spec) {
    const newId = editor.numericId.value;
    if (newId) await linkToOwner(spec, newId);
  }
};

const cancelChanges = () => {
  editor.reset();
  draftTagBindings.value = (originalTagBindings.value || []).map((b) => ({ ...b }));
};
const remove = editor.remove;
const duplicate = editor.duplicate;
const createNew = editor.createNew;
const goList = editor.goList;
const imageInput = ref<HTMLInputElement | null>(null);

const triggerImageUpload = () => imageInput.value?.click();

const formatBytes = (value: number) => {
  const n = Number(value || 0);
  if (n < 1024) return `${n} B`;
  const kb = n / 1024;
  if (kb < 1024) return `${kb.toFixed(1)} KB`;
  const mb = kb / 1024;
  return `${mb.toFixed(1)} MB`;
};

const handleImageSelected = async (event: Event) => {
  const target = event.target as HTMLInputElement | null;
  const file = target?.files?.[0];
  if (target) target.value = '';
  if (!file || isNew.value || editor.numericId.value == null) return;

  try {
    const response = await uploadKnowledgeBlockImage(editor.numericId.value, file);
    form.image = response.image;
  } catch (error) {
    console.error(error);
    alert('Failed to upload image.');
  }
};

const removeImage = async () => {
  if (!form.image || isNew.value || editor.numericId.value == null) return;
  if (!window.confirm('Remove image?')) return;

  try {
    const response = await deleteKnowledgeBlockImage(editor.numericId.value);
    form.image = response.image;
  } catch (error) {
    console.error(error);
    alert('Failed to remove image.');
  }
};
</script>

<style scoped>
.share-banner {
  display: flex;
  gap: 8px;
  align-items: center;
  border-color: #bfd6f6;
  background: #f5f9ff;
}

.knowledge-block-content-editor {
  position: relative;
  border: 1px solid #ddd;
  border-radius: 6px;
  background: #fff;
  overflow: hidden;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}

.knowledge-block-content-editor--error {
  border-color: #c0392b;
  box-shadow: 0 0 0 1px rgba(192, 57, 43, 0.12);
}

.knowledge-block-content-editor__mirror {
  position: absolute;
  inset: 0;
  margin: 0;
  pointer-events: none;
  overflow: hidden;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  z-index: 2;
}

.knowledge-block-content-editor__mirror code {
  display: block;
  min-height: 100%;
  padding: 6px 8px;
  font: inherit;
  line-height: 1.5;
  white-space: inherit;
  overflow-wrap: inherit;
}

.knowledge-block-content-editor__textarea {
  position: relative;
  z-index: 1;
  border: 0;
  border-radius: 0;
  background: transparent;
  color: transparent;
  text-shadow: 0 0 0 #111;
  caret-color: #111;
  -webkit-text-fill-color: transparent;
  resize: vertical;
  min-height: 280px;
}

.knowledge-block-content-editor__textarea:focus {
  outline: none;
  box-shadow: none;
}

.knowledge-block-content-editor__textarea--empty {
  text-shadow: none;
  color: inherit;
  -webkit-text-fill-color: inherit;
}

.knowledge-block-content-editor__textarea::placeholder {
  color: #9ca3af;
  -webkit-text-fill-color: #9ca3af;
}

.knowledge-block-content-editor__hint {
  margin-top: 6px;
}

:deep(.knowledge-block-content-editor__comment) {
  color: #8f96a3;
}

:deep(.knowledge-block-content-editor__plain) {
  color: transparent;
}
</style>
