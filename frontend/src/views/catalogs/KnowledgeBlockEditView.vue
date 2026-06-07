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

      </div>

      <div class="card stack">
        <div class="tabs">
          <button class="tab" :class="{ active: blockTab === 'visual' }" type="button" @click="blockTab = 'visual'">
            Visual
          </button>
          <button class="tab" :class="{ active: blockTab === 'code' }" type="button" @click="blockTab = 'code'">
            Code
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
          <button class="tab" :class="{ active: blockTab === 'files' }" type="button" @click="blockTab = 'files'">
            Files ({{ filesTabCount }})
          </button>
          <button
            class="tab"
            :class="{ active: blockTab === 'details' }"
            type="button"
            @click="blockTab = 'details'"
          >
            Details
          </button>
        </div>

        <div v-if="blockTab === 'visual'" class="stack knowledge-block-visual">
          <div
            v-if="visualBlocks.length"
            :class="[
              'knowledge-block-visual__surface',
              errors.hasField('content') && 'knowledge-block-visual__surface--error',
            ]"
          >
            <template v-for="block in visualBlocks" :key="visualBlockKey(block)">
              <div v-if="block.kind === 'blank'" class="knowledge-block-visual__blank" aria-hidden="true"></div>
              <section
                v-else
                :class="[
                  'knowledge-block-visual__block',
                  `knowledge-block-visual__block--${block.kind}`,
                  isActiveVisualBlock(block) && 'knowledge-block-visual__block--active',
                  !visualEditingDisabled && 'knowledge-block-visual__block--editable',
                ]"
                :tabindex="visualEditingDisabled || isActiveVisualBlock(block) ? undefined : 0"
                :role="visualEditingDisabled || isActiveVisualBlock(block) ? undefined : 'button'"
                @click="handleVisualBlockClick(block, $event)"
                @keydown="handleVisualBlockKeydown(block, $event)"
              >
                <div v-if="isActiveVisualBlock(block)" class="knowledge-block-visual__block-toolbar">
                  <span class="knowledge-block-visual__block-kind">
                    {{ block.kind === 'comment' ? 'Comment' : 'Markdown' }}
                  </span>
                  <div class="knowledge-block-visual__block-actions">
                    <button
                      type="button"
                      class="knowledge-block-visual__source-button"
                      @pointerdown.prevent.stop
                      @click.stop="openCodeAtBlock(block)"
                    >
                      Edit source
                    </button>
                    <button
                      type="button"
                      class="knowledge-block-visual__source-button"
                      @pointerdown.prevent.stop
                      @click.stop="finishVisualEditing"
                    >
                      Done
                    </button>
                  </div>
                </div>
                <textarea
                  v-if="isActiveVisualBlock(block)"
                  ref="visualTextareaRef"
                  :class="[
                    'knowledge-block-visual__textarea',
                    block.kind === 'comment' && 'knowledge-block-visual__textarea--comment',
                  ]"
                  :value="activeVisualEdit?.value || ''"
                  spellcheck="false"
                  @input="updateActiveVisualBlock"
                  @keydown.escape.prevent="finishVisualEditing"
                  @keydown.ctrl.enter.prevent="finishVisualEditing"
                  @keydown.meta.enter.prevent="finishVisualEditing"
                  @click.stop
                  @blur="finishVisualEditing"
                ></textarea>
                <div
                  v-else-if="block.kind === 'comment'"
                  class="knowledge-block-visual__comment-body"
                  data-i18n-ignore
                >
                  {{ commentBodyFromSource(block.source) }}
                </div>
                <div
                  v-else
                  class="knowledge-block-visual__rendered"
                  data-i18n-ignore
                  v-html="renderVisualMarkdownBlock(block)"
                ></div>
              </section>
            </template>
          </div>
          <div v-else class="muted knowledge-block-visual__empty">Nothing to preview.</div>
          <div v-if="errors.hasField('content')" class="error-text">{{ errors.messageFor('content') }}</div>
        </div>

        <div v-else-if="blockTab === 'code'" class="stack">
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

        <div v-else-if="blockTab === 'files'" class="stack">
          <div class="flex" style="justify-content: space-between; align-items: center; gap: 10px">
            <div class="stack" style="gap: 2px">
              <strong>Files</strong>
              <div class="muted" style="font-size: 0.85rem">
                Only enabled files are visible to the model as file_id placeholders.
              </div>
            </div>
            <button type="button" :disabled="filesActionDisabled" @click="triggerFilesUpload">
              Attach files
            </button>
          </div>

          <input ref="filesInput" type="file" multiple style="display: none" @change="handleFilesSelected" />

          <p v-if="filesLoading" class="muted">Loading…</p>
          <p v-else-if="filesError" class="error-text">{{ filesError }}</p>

          <div v-else class="list">
            <div
              v-for="attachment in fileAttachments"
              :key="attachment.id"
              class="row knowledge-block-file-row"
              :class="{
                'knowledge-block-file-row--disabled': attachment.enabled === false,
                'knowledge-block-file-row--pending': isPendingAttachment(attachment),
              }"
            >
              <label class="knowledge-block-file-row__enabled">
                <input
                  type="checkbox"
                  :checked="attachment.enabled !== false"
                  :disabled="saving || sharedReadonly"
                  aria-label="Enabled"
                  title="Enabled"
                  @change="toggleAttachmentEnabled(attachment, $event)"
                />
                <span>Enabled</span>
              </label>
              <div class="knowledge-block-file-row__main">
                <a
                  v-if="!isPendingAttachment(attachment)"
                  class="knowledge-block-file-row__name"
                  :href="attachment.url"
                  target="_blank"
                  rel="noopener"
                  title="Download file"
                >
                  {{ attachment.filename }}
                </a>
                <span v-else class="knowledge-block-file-row__name">{{ attachment.filename }}</span>
                <div class="knowledge-block-file-row__meta">
                  {{ attachment.mime_type || 'application/octet-stream' }} · {{ formatBytes(attachment.size_bytes) }}
                  <span v-if="isPendingAttachment(attachment)"> · <span>Pending upload</span></span>
                </div>
                <div class="knowledge-block-file-row__id">
                  <span class="muted">File ID</span>
                  <code v-if="attachment.file_id">{{ attachment.file_id }}</code>
                  <span v-else class="muted">Available after save</span>
                </div>
              </div>
              <button
                type="button"
                class="danger"
                :disabled="saving || sharedReadonly"
                @click="removeAttachment(attachment)"
              >
                Remove
              </button>
            </div>

            <p v-if="!fileAttachments.length" class="muted">No files attached.</p>
          </div>
          <div v-if="isNew" class="muted" style="font-size: 0.85rem">
            Files will be uploaded when you save the block.
          </div>
          <div v-else-if="filesDirty" class="muted" style="font-size: 0.85rem">
            File changes will be saved when you save the block.
          </div>
        </div>

        <div v-else class="stack">
          <div style="font-weight: 700">Details</div>
          <div class="stack">
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
import { computed, nextTick, ref, toRef, watch } from 'vue';
import { useRoute } from 'vue-router';
import { getApiErrorMessage } from '@/api/client';
import CrudHeader from '@/components/CrudHeader.vue';
import ImageThumbnail from '@/components/ImageThumbnail.vue';
import KnowledgeTagsPickerModal from '@/components/KnowledgeTagsPickerModal.vue';
import VariablesTable from '@/components/VariablesTable.vue';
import { deleteKnowledgeBlockImage, uploadKnowledgeBlockImage } from '@/api/images';
import { useLocalTextDraft } from '@/features/app/useLocalTextDraft';
import { useCrudEditor } from '@/features/catalogs/model/useCrudEditor';
import {
  isPendingKnowledgeBlockFile,
  useKnowledgeBlockFileBindingsDraft,
  type KnowledgeBlockFileDraftItem,
} from '@/features/catalogs/model/useKnowledgeBlockFileBindingsDraft';
import {
  COMMENT_PREFIX,
  commentBodyFromSource,
  commentSourceFromBody,
  parseKnowledgeBlockMarkdownBlocks,
  replaceKnowledgeBlockRange,
  stripKnowledgeBlockComments,
  type KnowledgeBlockMarkdownBlock,
} from '@/features/catalogs/model/knowledgeBlockMarkdownBlocks';
import { useUnsavedChangesGuard } from '@/features/catalogs/model/useUnsavedChangesGuard';
import { parseImageAsset } from '@/features/media/image';
import { renderChatMessageHtml } from '@/utils/chatMarkdown';
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
    applyKnowledgeBlockDocument(payload);
  },
});

const form = editor.form;
const contentDraftValue = toRef(form, 'content');
const errors = editor.errors;
const isNew = editor.isNew;
const loaded = editor.loaded;
const loading = editor.loading;
const loadError = editor.loadError;
const sharedReadonly = computed(() => !isNew.value && form.can_edit === false);
const filesInput = ref<HTMLInputElement | null>(null);
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
const blockTab = ref<'visual' | 'code' | 'variables' | 'tags' | 'files' | 'details'>('visual');
const initializedTabForId = ref<string | null>(null);

function getInitialBlockTab() {
  return isNew.value || !stripKnowledgeBlockComments(form.content).trim() ? 'code' : 'visual';
}

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
    initializedTabForId.value = null;
    tagModalOpen.value = false;
    linkedAfterCreate.value = false;
    activeVisualEdit.value = null;
    contentScrollTop.value = 0;
    contentScrollLeft.value = 0;
    if (contentTextareaRef.value) {
      contentTextareaRef.value.scrollTop = 0;
      contentTextareaRef.value.scrollLeft = 0;
    }
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

const filesTabCount = computed(() => fileAttachments.value.length);
const filesActionDisabled = computed(
  () =>
    saving.value ||
    sharedReadonly.value ||
    filesLoading.value ||
    (!isNew.value && !fileBindings.loaded.value)
);

const saving = computed(() => editor.saving.value || linking.value || fileBindings.syncing.value);
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

const contentTextareaRef = ref<HTMLTextAreaElement | null>(null);
const visualTextareaRef = ref<HTMLTextAreaElement | HTMLTextAreaElement[] | null>(null);
const contentScrollTop = ref(0);
const contentScrollLeft = ref(0);

type ActiveVisualEdit = {
  kind: 'markdown' | 'comment';
  start: number;
  end: number;
  key: string;
  value: string;
  trailingLineBreaks: string;
};

type ScrollSnapshot = {
  windowX: number;
  windowY: number;
  elements: Array<{
    element: HTMLElement;
    scrollLeft: number;
    scrollTop: number;
  }>;
};

const activeVisualEdit = ref<ActiveVisualEdit | null>(null);
const visualBlocks = computed(() => parseKnowledgeBlockMarkdownBlocks(form.content));
const visualEditingDisabled = computed(
  () => loading.value || saving.value || Boolean(loadError.value) || sharedReadonly.value
);

function trailingLineBreaks(source: string) {
  return source.match(/(?:\r\n|\n|\r)+$/u)?.[0] || '';
}

function lineBreakTokens(source: string) {
  return source.match(/\r\n|\n|\r/gu) || [];
}

function ensureTrailingLineBreaks(source: string, requiredSuffix: string) {
  if (!source || !requiredSuffix) return source;

  const required = lineBreakTokens(requiredSuffix);
  const existing = lineBreakTokens(trailingLineBreaks(source));
  if (existing.length >= required.length) return source;

  return `${source}${required.slice(existing.length).join('')}`;
}

function editableMarkdownSource(source: string) {
  const suffix = trailingLineBreaks(source);
  const tokens = lineBreakTokens(suffix);
  if (tokens.length <= 1) return source;

  return `${source.slice(0, source.length - suffix.length)}${tokens[0]}`;
}

function isActiveVisualBlock(block: KnowledgeBlockMarkdownBlock) {
  return Boolean(
    activeVisualEdit.value &&
      block.kind === activeVisualEdit.value.kind &&
      block.start === activeVisualEdit.value.start
  );
}

function visualBlockKey(block: KnowledgeBlockMarkdownBlock) {
  return isActiveVisualBlock(block) ? activeVisualEdit.value?.key || block.key : block.key;
}

function renderVisualMarkdownBlock(block: KnowledgeBlockMarkdownBlock) {
  return renderChatMessageHtml(block.source, { highlightCode: true });
}

async function startVisualEdit(block: KnowledgeBlockMarkdownBlock, sourceElement?: HTMLElement | null) {
  if (visualEditingDisabled.value || block.kind === 'blank') return;

  const scrollSnapshot = captureScrollSnapshot(sourceElement);
  const editableSource =
    block.kind === 'comment'
      ? commentBodyFromSource(block.source)
      : editableMarkdownSource(block.source);

  activeVisualEdit.value = {
    kind: block.kind,
    start: block.start,
    end: block.kind === 'comment' ? block.end : block.start + editableSource.length,
    key: block.key,
    value: editableSource,
    trailingLineBreaks:
      block.kind === 'comment'
        ? trailingLineBreaks(block.source)
        : trailingLineBreaks(editableSource),
  };

  await nextTick();
  const textarea = getVisualTextareaElement();
  if (!textarea) return;

  resizeVisualTextarea(textarea);
  restoreScrollSnapshot(scrollSnapshot);
  focusVisualTextarea(textarea, scrollSnapshot);
  resizeVisualTextareaSoon(textarea, scrollSnapshot);
}

function handleVisualBlockClick(block: KnowledgeBlockMarkdownBlock, event: MouseEvent) {
  const target = event.target as HTMLElement | null;
  if (target?.closest('button, textarea')) return;

  event.preventDefault();
  void startVisualEdit(block, event.currentTarget as HTMLElement | null);
}

function handleVisualBlockKeydown(block: KnowledgeBlockMarkdownBlock, event: KeyboardEvent) {
  if (event.target !== event.currentTarget) return;
  if (event.key !== 'Enter' && event.key !== ' ') return;

  event.preventDefault();
  void startVisualEdit(block, event.currentTarget as HTMLElement | null);
}

function updateActiveVisualBlock(event: Event) {
  const active = activeVisualEdit.value;
  const target = event.target as HTMLTextAreaElement | null;
  if (!active || !target) return;

  const nextValue = target.value;
  let nextSource = active.kind === 'comment' ? commentSourceFromBody(nextValue) : nextValue;
  const currentContent = form.content;
  const removedSource = currentContent.slice(active.start, active.end);
  const requiredTrailingLineBreaks = trailingLineBreaks(removedSource) || active.trailingLineBreaks;

  nextSource = ensureTrailingLineBreaks(nextSource, requiredTrailingLineBreaks);

  form.content = replaceKnowledgeBlockRange(currentContent, active.start, active.end, nextSource);
  errors.clearField('content');

  if (active.kind === 'comment' && !nextSource) {
    activeVisualEdit.value = null;
    return;
  }

  activeVisualEdit.value = {
    ...active,
    end: active.start + nextSource.length,
    value: nextValue,
  };
  resizeVisualTextareaSoon(target);
}

function finishVisualEditing() {
  activeVisualEdit.value = null;
}

function getVisualTextareaElement() {
  const textarea = visualTextareaRef.value;
  return Array.isArray(textarea) ? textarea[0] ?? null : textarea;
}

function resizeVisualTextareaSoon(textarea?: HTMLTextAreaElement | null, scrollSnapshot?: ScrollSnapshot | null) {
  const initialSelectionStart = textarea?.selectionStart;
  const initialSelectionEnd = textarea?.selectionEnd;
  const resize = () => {
    const element = textarea && document.body.contains(textarea) ? textarea : getVisualTextareaElement();
    if (!element) return;

    resizeVisualTextarea(element);
    if (
      scrollSnapshot &&
      document.activeElement === element &&
      element.selectionStart === initialSelectionStart &&
      element.selectionEnd === initialSelectionEnd
    ) {
      restoreScrollSnapshot(scrollSnapshot);
    }
  };

  resize();
  window.requestAnimationFrame(resize);
  window.requestAnimationFrame(() => {
    window.requestAnimationFrame(resize);
  });
  window.setTimeout(resize, 120);
}

function resizeVisualTextarea(textarea: HTMLTextAreaElement) {
  const style = window.getComputedStyle(textarea);
  const fontSize = Number.parseFloat(style.fontSize) || 14;
  const lineHeight = getResolvedLineHeight(style, fontSize);
  const paddingY = (Number.parseFloat(style.paddingTop) || 0) + (Number.parseFloat(style.paddingBottom) || 0);
  const borderY = (Number.parseFloat(style.borderTopWidth) || 0) + (Number.parseFloat(style.borderBottomWidth) || 0);
  const minHeight = Math.ceil(lineHeight + paddingY + borderY);
  const viewportHeight = window.visualViewport?.height || window.innerHeight || 720;
  const maxHeight = Math.max(minHeight, Math.min(720, viewportHeight * 0.68));

  textarea.style.height = 'auto';

  const contentHeight = textarea.scrollHeight + (style.boxSizing === 'border-box' ? borderY : 0);
  const nextHeight = Math.ceil(Math.max(minHeight, Math.min(maxHeight, contentHeight)));

  textarea.style.height = `${nextHeight}px`;
  textarea.style.overflowY = contentHeight > maxHeight ? 'auto' : 'hidden';
}

function focusVisualTextarea(textarea: HTMLTextAreaElement, scrollSnapshot: ScrollSnapshot) {
  try {
    textarea.focus({ preventScroll: true });
  } catch {
    textarea.focus();
  }

  restoreScrollSnapshot(scrollSnapshot);
  window.requestAnimationFrame(() => {
    if (document.activeElement === textarea) restoreScrollSnapshot(scrollSnapshot);
  });
}

function captureScrollSnapshot(anchor?: HTMLElement | null): ScrollSnapshot {
  const elements: ScrollSnapshot['elements'] = [];
  const seen = new Set<HTMLElement>();
  let element = anchor?.parentElement ?? null;

  while (element && element !== document.body) {
    if (
      !seen.has(element) &&
      (element.scrollHeight > element.clientHeight || element.scrollWidth > element.clientWidth)
    ) {
      elements.push({
        element,
        scrollLeft: element.scrollLeft,
        scrollTop: element.scrollTop,
      });
      seen.add(element);
    }
    element = element.parentElement;
  }

  return {
    windowX: window.scrollX,
    windowY: window.scrollY,
    elements,
  };
}

function restoreScrollSnapshot(snapshot: ScrollSnapshot) {
  for (const item of snapshot.elements) {
    if (!document.body.contains(item.element)) continue;
    item.element.scrollLeft = item.scrollLeft;
    item.element.scrollTop = item.scrollTop;
  }
  window.scrollTo(snapshot.windowX, snapshot.windowY);
}

async function openCodeAtBlock(block: KnowledgeBlockMarkdownBlock) {
  activeVisualEdit.value = null;
  blockTab.value = 'code';

  await nextTick();
  const textarea = contentTextareaRef.value;
  if (!textarea) return;

  const position = Math.max(0, Math.min(String(form.content || '').length, block.start));
  textarea.focus({ preventScroll: true });
  textarea.setSelectionRange(position, position);
  scrollCodeEditorToPosition(textarea, position);
}

watch(blockTab, (tab) => {
  if (tab !== 'visual') finishVisualEditing();
});

function scrollCodeEditorToPosition(textarea: HTMLTextAreaElement, position: number) {
  const applyScroll = () => {
    if (!document.body.contains(textarea)) return;
    if (document.activeElement !== textarea) return;
    if (textarea.selectionStart !== position || textarea.selectionEnd !== position) return;

    applyCodeEditorScroll(textarea, getTextareaScrollTopForPosition(textarea, position));
  };

  applyScroll();
  window.requestAnimationFrame(applyScroll);
  window.requestAnimationFrame(() => {
    window.requestAnimationFrame(applyScroll);
  });
  window.setTimeout(applyScroll, 120);
  window.setTimeout(applyScroll, 320);
  window.setTimeout(applyScroll, 640);
}

function applyCodeEditorScroll(textarea: HTMLTextAreaElement, scrollTop: number) {
  textarea.scrollTop = scrollTop;
  contentScrollTop.value = textarea.scrollTop;
  contentScrollLeft.value = textarea.scrollLeft;
}

function getTextareaScrollTopForPosition(textarea: HTMLTextAreaElement, position: number) {
  const targetTop = measureTextareaPositionTop(textarea, position) ?? estimateTextareaPositionTop(textarea, position);
  const maxScrollTop = Math.max(0, textarea.scrollHeight - textarea.clientHeight);
  return Math.max(0, Math.min(maxScrollTop, targetTop - textarea.clientHeight * 0.35));
}

function estimateTextareaPositionTop(textarea: HTMLTextAreaElement, position: number) {
  const style = window.getComputedStyle(textarea);
  const fontSize = Number.parseFloat(style.fontSize) || 14;
  const lineHeight = getResolvedLineHeight(style, fontSize);
  const paddingTop = Number.parseFloat(style.paddingTop) || 0;
  const lineIndex = String(form.content || '').slice(0, position).split('\n').length - 1;
  return paddingTop + lineIndex * lineHeight;
}

function measureTextareaPositionTop(textarea: HTMLTextAreaElement, position: number) {
  const value = String(form.content || '');
  const style = window.getComputedStyle(textarea);
  const fontSize = Number.parseFloat(style.fontSize) || 14;
  const lineHeight = getResolvedLineHeight(style, fontSize);
  const resolvedLineHeight = `${lineHeight}px`;
  const overflowWrap = style.getPropertyValue('overflow-wrap');
  const mirror = document.createElement('div');
  const marker = document.createElement('span');

  Object.assign(mirror.style, {
    position: 'absolute',
    visibility: 'hidden',
    overflow: 'hidden',
    top: '0',
    left: '-9999px',
    width: `${textarea.clientWidth}px`,
    boxSizing: 'border-box',
    paddingTop: style.paddingTop,
    paddingRight: style.paddingRight,
    paddingBottom: style.paddingBottom,
    paddingLeft: style.paddingLeft,
    fontFamily: style.fontFamily,
    fontSize: style.fontSize,
    fontStyle: style.fontStyle,
    fontVariant: style.fontVariant,
    fontWeight: style.fontWeight,
    letterSpacing: style.letterSpacing,
    lineHeight: resolvedLineHeight,
    textTransform: style.textTransform,
    whiteSpace: 'pre-wrap',
    overflowWrap: !overflowWrap || overflowWrap === 'normal' ? 'break-word' : overflowWrap,
    wordBreak: style.wordBreak,
    tabSize: style.getPropertyValue('tab-size') || '8',
  });

  Object.assign(marker.style, {
    display: 'inline-block',
    width: '1px',
    height: resolvedLineHeight,
    lineHeight: resolvedLineHeight,
  });

  marker.textContent = '\u200b';
  mirror.append(document.createTextNode(value.slice(0, position)), marker);
  document.body.append(mirror);

  const top = marker.offsetTop;
  mirror.remove();
  return Number.isFinite(top) ? top : null;
}

function getResolvedLineHeight(style: CSSStyleDeclaration, fontSize: number) {
  return Number.parseFloat(style.lineHeight) || fontSize * 1.5;
}

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
  activeVisualEdit.value = null;
  editor.reset();
  draftTagBindings.value = (originalTagBindings.value || []).map((b) => ({ ...b }));
  fileBindings.reset();
};
const remove = editor.remove;
const duplicate = editor.duplicate;
const createNew = editor.createNew;
const goList = editor.goList;
const imageInput = ref<HTMLInputElement | null>(null);

const triggerImageUpload = () => imageInput.value?.click();
const triggerFilesUpload = () => filesInput.value?.click();

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
    alert(getApiErrorMessage(error, 'Failed to upload image.'));
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

const handleFilesSelected = (event: Event) => {
  const target = event.target as HTMLInputElement | null;
  const files = Array.from(target?.files || []);
  if (target) target.value = '';
  if (!files.length || sharedReadonly.value || filesActionDisabled.value) return;

  fileBindings.addFiles(files);
};

const removeAttachment = (attachment: KnowledgeBlockFileDraftItem) => {
  if (sharedReadonly.value) return;
  fileBindings.remove(attachment.id);
};

function toggleAttachmentEnabled(attachment: KnowledgeBlockFileDraftItem, event: Event) {
  if (sharedReadonly.value) return;
  const target = event.target as HTMLInputElement | null;
  if (!target) return;

  fileBindings.setEnabled(attachment.id, Boolean(target.checked));
}

const isPendingAttachment = isPendingKnowledgeBlockFile;
</script>

<style scoped>
.share-banner {
  display: flex;
  gap: 8px;
  align-items: center;
  border-color: var(--color-info-border);
  background: var(--color-info-bg);
}

.knowledge-block-visual {
  min-height: 280px;
}

.knowledge-block-visual__surface {
  min-height: 280px;
  border: 1px solid var(--color-border-strong);
  border-radius: 6px;
  padding: 8px;
  background: var(--color-surface);
  overflow: auto;
}

.knowledge-block-visual__surface--error {
  border-color: var(--color-danger);
  box-shadow: 0 0 0 1px color-mix(in srgb, var(--color-danger) 22%, transparent);
}

.knowledge-block-visual__empty {
  min-height: 280px;
  border: 1px dashed var(--color-border-strong);
  border-radius: 6px;
  padding: 14px 16px;
  background: var(--color-surface-subtle);
}

.knowledge-block-visual__block {
  position: relative;
  min-width: 0;
  border: 1px solid transparent;
  border-radius: 6px;
  padding: 6px 8px;
}

.knowledge-block-visual__block--editable {
  cursor: text;
}

.knowledge-block-visual__block--editable:hover {
  border-color: var(--color-border);
  background: var(--color-surface-subtle);
}

.knowledge-block-visual__block--active {
  border-color: var(--color-focus);
  background: var(--color-surface);
  box-shadow: 0 0 0 1px color-mix(in srgb, var(--color-focus) 22%, transparent);
}

.knowledge-block-visual__block--comment {
  color: var(--color-text-subtle);
  background: var(--color-surface-subtle);
}

.knowledge-block-visual__blank {
  height: 10px;
}

.knowledge-block-visual__block-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 6px;
}

.knowledge-block-visual__block-kind {
  color: var(--color-text-muted);
  font-size: 0.75rem;
  font-weight: 650;
  text-transform: uppercase;
}

.knowledge-block-visual__block-actions {
  display: flex;
  align-items: center;
  gap: 6px;
}

.knowledge-block-visual__source-button {
  padding: 3px 7px;
  font-size: 0.78rem;
}

.knowledge-block-visual__textarea {
  display: block;
  width: 100%;
  min-height: 0;
  overflow-anchor: none;
  resize: vertical;
  overflow-y: hidden;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.92rem;
  line-height: 1.5;
}

.knowledge-block-visual__textarea--comment {
  color: var(--color-text-muted);
  background: var(--color-surface-muted);
}

.knowledge-block-visual__comment-body {
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  word-break: break-word;
}

:deep(.knowledge-block-visual__rendered :where(h1, h2, h3, h4, h5, h6)) {
  margin: 10px 0 8px;
  font-weight: 650;
  line-height: 1.25;
}

:deep(.knowledge-block-visual__rendered h1) {
  font-size: 1.25rem;
}

:deep(.knowledge-block-visual__rendered h2) {
  font-size: 1.15rem;
}

:deep(.knowledge-block-visual__rendered h3) {
  font-size: 1.05rem;
}

:deep(.knowledge-block-visual__rendered :where(h4, h5, h6)) {
  font-size: 1rem;
}

:deep(.knowledge-block-visual__rendered :where(p, li, blockquote, h1, h2, h3, h4, h5, h6, td, th)) {
  overflow-wrap: anywhere;
  word-break: break-word;
}

:deep(.knowledge-block-visual__rendered p) {
  margin: 0 0 8px;
}

:deep(.knowledge-block-visual__rendered p:last-child) {
  margin-bottom: 0;
}

:deep(.knowledge-block-visual__rendered ul),
:deep(.knowledge-block-visual__rendered ol) {
  margin: 0 0 8px 18px;
  padding: 0;
}

:deep(.knowledge-block-visual__rendered blockquote) {
  margin: 0 0 8px;
  padding-left: 12px;
  border-left: 3px solid var(--color-border-strong);
  color: var(--color-text-muted);
}

:deep(.knowledge-block-visual__rendered code) {
  background: var(--color-surface-hover);
  border-radius: 6px;
  padding: 2px 6px;
  font-size: 0.95em;
}

:deep(.knowledge-block-visual__rendered pre) {
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  margin: 0 0 8px;
  padding: 10px;
  overflow-x: auto;
  border-radius: 10px;
  background: var(--color-code-bg);
  color: var(--color-code-text);
  font-size: 0.82rem;
  line-height: 1.4;
}

:deep(.knowledge-block-visual__rendered pre code) {
  display: block;
  padding: 0;
  border-radius: 0;
  background: transparent;
  color: inherit;
  font-size: inherit;
  line-height: inherit;
}

:deep(.knowledge-block-visual__rendered table) {
  width: 100%;
  border-collapse: collapse;
}

:deep(.knowledge-block-visual__rendered th),
:deep(.knowledge-block-visual__rendered td) {
  border: 1px solid var(--color-border-strong);
  padding: 6px 8px;
  text-align: left;
}

:deep(.knowledge-block-visual__rendered math.tml-display) {
  margin: 0 0 8px;
  overflow-x: auto;
  overflow-y: hidden;
}

:deep(.knowledge-block-visual__rendered math) {
  max-width: 100%;
}

.knowledge-block-file-row {
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.knowledge-block-file-row--disabled .knowledge-block-file-row__main {
  opacity: 0.58;
}

.knowledge-block-file-row--pending {
  border-style: dashed;
  background: var(--color-info-bg);
}

.knowledge-block-file-row__enabled {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  margin: 0;
  font-size: 0.85rem;
  white-space: nowrap;
}

.knowledge-block-file-row__enabled input {
  width: 16px;
  height: 16px;
  margin: 0;
}

.knowledge-block-file-row__main {
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.knowledge-block-file-row__name {
  font-weight: 600;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.knowledge-block-file-row__meta {
  color: var(--color-text-muted);
  font-size: 0.85rem;
}

.knowledge-block-file-row__id {
  display: flex;
  align-items: baseline;
  gap: 6px;
  min-width: 0;
  font-size: 0.78rem;
}

.knowledge-block-file-row__id code {
  min-width: 0;
  overflow-wrap: anywhere;
  word-break: break-word;
}

.knowledge-block-content-editor {
  position: relative;
  border: 1px solid var(--color-border-strong);
  border-radius: 6px;
  background: var(--color-surface);
  overflow: hidden;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}

.knowledge-block-content-editor--error {
  border-color: var(--color-danger);
  box-shadow: 0 0 0 1px color-mix(in srgb, var(--color-danger) 22%, transparent);
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
  text-shadow: 0 0 0 var(--color-text);
  caret-color: var(--color-text);
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
  color: var(--color-text-subtle);
  -webkit-text-fill-color: var(--color-text-subtle);
}

.knowledge-block-content-editor__hint {
  margin-top: 6px;
}

@media (max-width: 640px) {
  .knowledge-block-content-editor {
    font-size: 1rem;
  }
}

:deep(.knowledge-block-content-editor__comment) {
  color: var(--color-text-subtle);
}

:deep(.knowledge-block-content-editor__plain) {
  color: transparent;
}
</style>
