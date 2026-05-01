<template>
  <div v-if="loaded" class="stack">
    <CrudHeader
      title="Bot"
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
    >
      <template #menu-extra>
        <button v-if="!isNew && !sharedReadonly" class="menu-item" type="button" @click="openShareModal">
          Share…
        </button>
      </template>
    </CrudHeader>

    <p v-if="loadError" class="error-text">{{ loadError }}</p>
    <div v-if="sharedReadonly" class="card share-banner">
      <strong>Shared with you.</strong> This bot is read-only. Duplicate it to create an editable copy.
    </div>

    <fieldset class="stack" :disabled="loading || saving || Boolean(loadError)">
      <div v-if="loading" class="loading-float" aria-live="polite">Loading…</div>
      <div class="card stack">
        <div v-if="errors.formErrors.length" class="error-text">{{ errors.formErrors.join(' ') }}</div>

        <label :class="{ 'field-error': errors.hasField('name') }">
          Name
          <input v-model="form.name" class="full" :disabled="sharedReadonly" @input="errors.clearField('name')" />
          <div v-if="errors.hasField('name')" class="error-text">{{ errors.messageFor('name') }}</div>
        </label>
      </div>

      <div class="card stack">
        <div class="flex" style="justify-content: space-between; align-items: center; gap: 10px">
          <div class="stack" style="gap: 2px">
            <strong>Image</strong>
            <div class="muted" style="font-size: 0.85rem">Used as the bot avatar.</div>
          </div>
          <div class="flex" style="gap: 8px">
            <button type="button" :disabled="isNew || saving || sharedReadonly" @click="triggerImageUpload">Upload</button>
            <button type="button" class="danger" :disabled="!form.image || saving || sharedReadonly" @click="removeImage">
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
        <div v-if="isNew" class="muted" style="font-size: 0.85rem">Save the bot before uploading an image.</div>
      </div>

      <div class="card stack">
        <div class="tabs">
          <button class="tab" :class="{ active: botTab === 'blocks' }" type="button" @click="botTab = 'blocks'">
            Blocks
          </button>
          <button
            class="tab"
            :class="{ active: botTab === 'firstMessages' }"
            type="button"
            @click="botTab = 'firstMessages'"
          >
            First messages
          </button>
          <button class="tab" :class="{ active: botTab === 'tools' }" type="button" @click="botTab = 'tools'">
            Tools
          </button>
          <button class="tab" :class="{ active: botTab === 'context' }" type="button" @click="botTab = 'context'">
            Context
          </button>
          <button class="tab" :class="{ active: botTab === 'configTags' }" type="button" @click="botTab = 'configTags'">
            Config tags
          </button>
          <button
            class="tab"
            :class="{ active: botTab === 'variables' }"
            type="button"
            @click="botTab = 'variables'"
          >
            Variables
          </button>
        </div>

        <div v-if="botTab === 'blocks'" class="stack">
          <BotKnowledgeBlocksSection
            :resetKey="editor.idParam.value"
            :items="bindings.draft.value"
            :knowledgeBlocks="knowledgeBlocks"
            :linkedBlockIds="linkedBlockIds"
            :bindingsLoaded="bindings.loaded.value"
            :bindingsLoading="bindings.loading.value"
            :bindingsError="bindings.error.value"
            :saving="saving.value"
            :isNew="isNew"
            :sharedReadonly="sharedReadonly"
            :blockName="blockName"
            :blockImage="blockImage"
            :blockVersion="blockVersion"
            @add-blocks="bindings.addBlocks"
            @open-new-block="openNewBlock"
            @open-block-editor="openBlockEditor"
            @move="bindings.move"
            @remove="bindings.remove"
            @set-enabled="bindings.setEnabled"
          />
        </div>

        <div v-else-if="botTab === 'tools'" class="stack">
          <BotToolsSection
            :isNew="isNew"
            :sharedReadonly="sharedReadonly"
            :resetKey="editor.idParam.value"
            :toolLibrary="toolLibrary"
            :ownedToolLibrary="ownedToolLibrary"
            :toolLibraryLoading="toolLibraryLoading"
            :toolLibraryError="toolLibraryError"
            :toolBindingsLoading="toolBindings.loading.value"
            :toolBindingsError="toolBindings.error.value"
            :toolBindingsSaving="toolBindingsSaving"
            :sortedToolBindings="toolBindings.sortedToolBindings.value"
            :perUserBaseBindings="toolBindings.perUserBaseBindings.value"
            :userToolBindingsLoading="userToolOverrides.loading.value"
            :userToolBindingsError="userToolOverrides.error.value"
            :userToolBindingSavingAliases="userToolOverrides.savingAliases.value"
            :toolBindingLabel="toolBindingLabel"
            :toolBindingIsOutlet="toolBindingIsOutlet"
            :toolBindingIsOnline="toolBindingIsOnline"
            :userToolDraft="userToolOverrides.userToolDraft"
            :userToolBindingLabel="userToolOverrides.label"
            :addToolBinding="addToolBinding"
            @load-tool-library="loadToolLibrary"
            @move-tool-binding="toolBindings.move"
            @remove-tool-binding="removeToolBindingById"
            @toggle-tool-binding="toolBindings.toggle"
            @set-user-tool-draft-tool="userToolOverrides.setDraftTool"
            @toggle-user-tool-draft-enabled="userToolOverrides.toggleDraftEnabled"
            @save-user-tool-binding="userToolOverrides.saveOverride"
            @remove-user-tool-binding="userToolOverrides.removeOverride"
          />
        </div>

        <div
          v-else-if="botTab === 'firstMessages'"
          :class="['stack', errors.hasField('first_messages') && 'field-error']"
        >
          <div v-if="errors.hasField('first_messages')" class="error-text">{{ errors.messageFor('first_messages') }}</div>
          <div class="flex" style="justify-content: space-between; align-items: center; gap: 10px">
            <strong>First messages</strong>
            <button type="button" @click="addFirstMessage" :disabled="saving || sharedReadonly">Add</button>
          </div>

          <div v-if="form.first_messages.length" class="stack" style="gap: 10px">
            <div
              v-for="(msg, idx) in form.first_messages"
              :key="`fm-${idx}`"
              class="row"
              style="align-items: flex-start"
            >
              <div style="flex: 1; min-width: 0">
                <textarea
                  v-model="form.first_messages[idx]"
                  class="full"
                  rows="3"
                  placeholder="Message"
                  :disabled="sharedReadonly"
                  @input="errors.clearField('first_messages')"
                ></textarea>
                <div class="muted" style="font-size: 0.85rem">Order {{ idx + 1 }}</div>
              </div>
              <div class="flex" style="gap: 8px; align-items: center">
                <button type="button" :disabled="sharedReadonly || idx === 0" @click="moveFirstMessage(idx, -1)">↑</button>
                <button
                  type="button"
                  :disabled="sharedReadonly || idx === form.first_messages.length - 1"
                  @click="moveFirstMessage(idx, 1)"
                >
                  ↓
                </button>
                <button type="button" :disabled="sharedReadonly" @click="removeFirstMessage(idx)">✕</button>
              </div>
            </div>
          </div>
          <p v-else class="muted">No first messages yet.</p>
        </div>

        <div v-else-if="botTab === 'context'" class="stack">
          <label :class="{ 'field-error': errors.hasField('max_tool_rounds') }">
            Max tool rounds
            <input
              v-model.number="form.max_tool_rounds"
              type="number"
              min="0"
              class="full"
              :disabled="sharedReadonly"
              @input="errors.clearField('max_tool_rounds')"
            />
            <div v-if="errors.hasField('max_tool_rounds')" class="error-text">
              {{ errors.messageFor('max_tool_rounds') }}
            </div>
          </label>

          <label :class="{ 'field-error': errors.hasField('context_soft_limit_percent') }">
            Context soft limit (%)
            <input
              v-model.number="form.context_soft_limit_percent"
              type="number"
              min="1"
              max="100"
              class="full"
              :disabled="sharedReadonly"
              @input="errors.clearField('context_soft_limit_percent')"
            />
            <div v-if="errors.hasField('context_soft_limit_percent')" class="error-text">
              {{ errors.messageFor('context_soft_limit_percent') }}
            </div>
          </label>

          <div class="stack" style="gap: 6px">
            <label style="display: flex; align-items: center; gap: 10px">
              <input v-model="form.supports_file_processing" type="checkbox" :disabled="sharedReadonly" />
              Supports file processing
            </label>
            <div class="muted">Allow any file types in chats for this bot.</div>
          </div>

          <label :class="{ 'field-error': errors.hasField('max_file_size_bytes') }">
            Max file size (MB)
            <input
              v-model.number="form.max_file_size_mb"
              type="number"
              min="1"
              class="full"
              :disabled="sharedReadonly"
              @input="errors.clearField('max_file_size_bytes')"
            />
            <div v-if="errors.hasField('max_file_size_bytes')" class="error-text">
              {{ errors.messageFor('max_file_size_bytes') }}
            </div>
          </label>
        </div>

        <div v-else-if="botTab === 'configTags'" class="stack">
          <div class="flex" style="justify-content: space-between; align-items: center; gap: 10px">
            <strong>Compatible configuration tags</strong>
            <button
              type="button"
              @click="compatibleTagsPickerOpen = true"
              :disabled="saving || configurationTagsLoading || sharedReadonly"
            >
              Add tags
            </button>
          </div>

          <div class="muted">
            If the list is empty, chats with this bot will not filter the configuration selector.
          </div>

          <p v-if="configurationTagsLoading" class="muted">Loading…</p>
          <p v-else-if="configurationTagsError" class="error-text">{{ configurationTagsError }}</p>

          <div v-else-if="attachedCompatibleTags.length" class="list">
            <div v-for="tag in attachedCompatibleTags" :key="tag.id" class="row" style="align-items: center; gap: 8px">
              <div style="font-weight: 600; min-width: 0; overflow: hidden; text-overflow: ellipsis">
                {{ tag.name }}
              </div>
              <button type="button" :disabled="saving || sharedReadonly" @click="removeCompatibleTag(tag.id)">Remove</button>
            </div>
          </div>
          <p v-else class="muted">No compatible tags selected.</p>

          <p v-if="compatibleTagBindingsLoading" class="muted">Loading bindings…</p>
          <p v-else-if="compatibleTagBindingsError" class="error-text">{{ compatibleTagBindingsError }}</p>
          <p v-if="compatibleTagBindingsDirty" class="muted">Tag changes will be saved when you save the bot.</p>
        </div>

        <div v-else class="stack">
          <strong>Variables</strong>
          <VariablesTable :modelValue="variablesRows" :readonly="sharedReadonly" @update:modelValue="setVariablesRows" />
          <div class="muted">
            Variables are exposed to prompts as <code v-text="'{{key}}'"></code>.
          </div>
        </div>
      </div>
    </fieldset>

    <LlmConfigurationTagsPickerModal
      v-model:open="compatibleTagsPickerOpen"
      title="Select compatible tags"
      :tags="allConfigurationTags"
      :selectedTagIds="draftCompatibleTagIds"
      :loading="configurationTagsLoading"
      :error="configurationTagsError"
      @toggle="toggleCompatibleTag"
    />

    <BotShareWizardModal
      v-model:open="shareModalOpen"
      :groups="shareGroups"
      :selectedGroupIds="sharedGroupIds"
      :toolBindings="shareToolBindings"
      :loading="shareLoading"
      :saving="shareSaving"
      @save="saveSharing"
    />
  </div>

  <p v-else class="muted">Loading…</p>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { api, getApiErrorMessage } from '@/api/client';
import BotShareWizardModal, { type BotShareToolBinding } from '@/components/BotShareWizardModal.vue';
import CrudHeader from '@/components/CrudHeader.vue';
import ImageThumbnail from '@/components/ImageThumbnail.vue';
import VariablesTable from '@/components/VariablesTable.vue';
import LlmConfigurationTagsPickerModal from '@/components/LlmConfigurationTagsPickerModal.vue';
import { deleteBotImage, uploadBotImage } from '@/api/images';
import BotKnowledgeBlocksSection from '@/features/catalogs/components/BotKnowledgeBlocksSection.vue';
import BotToolsSection from '@/features/catalogs/components/BotToolsSection.vue';
import { useCrudEditor } from '@/features/catalogs/model/useCrudEditor';
import {
  useKnowledgeBlockBindingsDraft,
  type KnowledgeBlockLinkItem,
} from '@/features/catalogs/model/useKnowledgeBlockBindingsDraft';
import { useKnowledgeBlockNewDraft } from '@/features/catalogs/model/useKnowledgeBlockNewDraft';
import {
  parseBotToolBindingRow,
  useBotToolBindings,
  type BotToolBindingRow,
} from '@/features/catalogs/model/useBotToolBindings';
import {
  parseBotUserToolBindingRow,
  useBotUserToolOverrides,
} from '@/features/catalogs/model/useBotUserToolOverrides';
import { useUnsavedChangesGuard } from '@/features/catalogs/model/useUnsavedChangesGuard';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import { parseImageAsset } from '@/features/media/image';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import {
  mergeToolInstanceOptions,
  parseToolInstanceOption,
  useToolInstanceLibrary,
} from '@/features/tools/model/toolInstances';
import {
  createJsonApiIncludedIndex,
  jsonApiList,
  relatedResource,
  relatedResources,
  relationshipId,
  toIntId,
  type JsonApiResource,
  type JsonApiSingleResponse,
} from '@/api/jsonApi';
import type { Group, ImageAsset, KnowledgeBlock, ToolInstanceOption } from '@/types/api';

type BotForm = {
  name: string;
  image: ImageAsset | null;
  first_messages: string[];
  variables: Record<string, string>;
  max_tool_rounds: number;
  context_soft_limit_percent: number;
  supports_file_processing: boolean;
  max_file_size_mb: number;
  can_edit: boolean;
  shared_incoming: boolean;
  shared_outgoing: boolean;
};

type ConfigurationTagRow = { id: number; name: string };
type CompatibleTagBindingRow = { id: number; llm_configuration_tag_id: number; tag_name: string };

type ShareStateResponse = {
  group_ids?: number[];
  tool_modes?: Record<string, string>;
};

const route = useRoute();
const stackNav = useStackNavigation();
const stack = useNavigationStack();

const BOT_DOCUMENT_INCLUDE = [
  'knowledge_block_bindings.knowledge_block',
  'compatible_configuration_tag_bindings.llm_configuration_tag',
  'tool_bindings.tool_instance',
  'user_tool_bindings.tool_instance',
].join(',');

function normalizeTagIds(ids: number[]) {
  return Array.from(new Set((ids || []).filter((id): id is number => typeof id === 'number' && id > 0))).sort(
    (a, b) => a - b
  );
}

function fromApi(resource: JsonApiResource): Partial<BotForm> {
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const rawFirst = Array.isArray(attrs.first_messages) ? (attrs.first_messages as unknown[]) : [];
  const first_messages = rawFirst.map((m) => String(m || '')).filter((m) => m.trim() !== '');
  const variables = attrs.variables && typeof attrs.variables === 'object' ? (attrs.variables as any) : {};
  return {
    name: String(attrs.name || ''),
    image: parseImageAsset(attrs.image),
    first_messages,
    variables,
    max_tool_rounds:
      typeof attrs.max_tool_rounds === 'number' ? attrs.max_tool_rounds : Number(attrs.max_tool_rounds || 100),
    context_soft_limit_percent:
      typeof attrs.context_soft_limit_percent === 'number'
        ? attrs.context_soft_limit_percent
        : Number(attrs.context_soft_limit_percent || 80),
    supports_file_processing: Boolean(attrs.supports_file_processing),
    max_file_size_mb:
      typeof attrs.max_file_size_bytes === 'number'
        ? Math.max(1, Math.round(attrs.max_file_size_bytes / (1024 * 1024)))
        : 500,
    can_edit: attrs.can_edit !== false,
    shared_incoming: Boolean(attrs.shared_incoming),
    shared_outgoing: Boolean(attrs.shared_outgoing),
  };
}

function botDocumentQuery() {
  const qs = new URLSearchParams();
  qs.set('include', BOT_DOCUMENT_INCLUDE);
  return qs;
}

function parseConfigurationTagRow(resource: JsonApiResource | null | undefined): ConfigurationTagRow | null {
  if (!resource) return null;
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return { id, name: String(attrs.name || '').trim() };
}

function parseKnowledgeBlockOption(resource: JsonApiResource | null | undefined): KnowledgeBlock | null {
  if (!resource) return null;
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return {
    id,
    name: String(attrs.name || ''),
    image: parseImageAsset(attrs.image),
    type: typeof attrs.type === 'string' ? attrs.type : null,
    version: typeof attrs.version === 'string' ? attrs.version : null,
    token_count: typeof attrs.token_count === 'number' ? attrs.token_count : toIntId(attrs.token_count as any),
  } satisfies KnowledgeBlock;
}

function parseKnowledgeBlockBindingItem(
  resource: JsonApiResource,
  includedIndex: ReturnType<typeof createJsonApiIncludedIndex>
): KnowledgeBlockLinkItem | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const blockId =
    parseKnowledgeBlockOption(relatedResource(resource, 'knowledge_block', includedIndex))?.id ??
    relationshipId(resource, 'knowledge_block') ??
    toIntId(attrs.knowledge_block_id as any);

  if (!blockId) return null;

  return {
    id,
    block: blockId,
    enabled: Boolean(attrs.enabled),
    sequence: typeof attrs.sequence === 'number' ? attrs.sequence : Number(attrs.sequence || 0),
  };
}

function parseCompatibleTagBindingRow(
  resource: JsonApiResource,
  includedIndex: ReturnType<typeof createJsonApiIncludedIndex>
): CompatibleTagBindingRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const tagId =
    relationshipId(resource, 'llm_configuration_tag') ??
    (typeof attrs.llm_configuration_tag_id === 'number'
      ? attrs.llm_configuration_tag_id
      : toIntId(attrs.llm_configuration_tag_id as any));

  if (!tagId) return null;

  return {
    id,
    llm_configuration_tag_id: tagId,
    tag_name:
      parseConfigurationTagRow(relatedResource(resource, 'llm_configuration_tag', includedIndex))?.name ??
      String(attrs.tag_name || '').trim(),
  };
}

const editor = useCrudEditor<BotForm>({
  type: 'bots',
  basePath: '/api/ash/bots',
  indexPath: '/catalogs/bots',
  editPath: (id) => `/catalogs/bots/${id}`,
  defaultForm: () => ({
    name: '',
    image: null,
    first_messages: [],
    variables: {},
    max_tool_rounds: 100,
    context_soft_limit_percent: 80,
    supports_file_processing: false,
    max_file_size_mb: 500,
    can_edit: true,
    shared_incoming: false,
    shared_outgoing: false,
  }),
  fromApi,
  toAttributes: (form) => ({
    name: form.name,
    first_messages: (form.first_messages || []).map((m) => String(m || '').trim()).filter((m) => m !== ''),
    variables: form.variables || {},
    max_tool_rounds: form.max_tool_rounds,
    context_soft_limit_percent: form.context_soft_limit_percent,
    supports_file_processing: form.supports_file_processing,
    max_file_size_bytes: Math.max(1, Number(form.max_file_size_mb || 500)) * 1024 * 1024,
    ...(compatibleTagBindingsPayload.value === undefined
      ? {}
      : { compatible_configuration_tag_bindings: compatibleTagBindingsPayload.value }),
    ...(bindings.payload.value === undefined ? {} : { knowledge_block_bindings: bindings.payload.value }),
    ...(toolBindings.payload.value === undefined ? {} : { tool_bindings: toolBindings.payload.value }),
  }),
  normalizeForDirty: (form) => ({
    name: form.name,
    first_messages: form.first_messages,
    variables: form.variables,
    max_tool_rounds: form.max_tool_rounds,
    context_soft_limit_percent: form.context_soft_limit_percent,
    supports_file_processing: form.supports_file_processing,
    max_file_size_mb: form.max_file_size_mb,
    can_edit: form.can_edit,
    shared_incoming: form.shared_incoming,
    shared_outgoing: form.shared_outgoing,
  }),
  duplicatePath: (id) => `/api/ash/bots/${id}/duplicate`,
  documentQuery: () => botDocumentQuery(),
  onDocument: (payload) => {
    applyBotDocument(payload);
  },
});

const bindings = useKnowledgeBlockBindingsDraft({});
const toolBindings = useBotToolBindings();

const allConfigurationTags = ref<ConfigurationTagRow[]>([]);
const configurationTagsCatalogLoaded = ref(false);
const configurationTagsLoading = ref(false);
const configurationTagsError = ref<string | null>(null);
const compatibleTagBindingsLoading = ref(false);
const compatibleTagBindingsError = ref<string | null>(null);
const currentCompatibleTagBindings = ref<CompatibleTagBindingRow[]>([]);
const draftCompatibleTagIds = ref<number[]>([]);
const compatibleTagsPickerOpen = ref(false);

const attachedCompatibleTags = computed(() => {
  const tagMap = new Map<number, ConfigurationTagRow>();
  for (const tag of allConfigurationTags.value) tagMap.set(tag.id, tag);
  for (const binding of currentCompatibleTagBindings.value) {
    const name = String(binding.tag_name || '').trim();
    if (!name) continue;
    tagMap.set(binding.llm_configuration_tag_id, { id: binding.llm_configuration_tag_id, name });
  }
  return draftCompatibleTagIds.value.map((id) => tagMap.get(id) || { id, name: `Tag #${id}` });
});

function mergeConfigurationTags(tags: ConfigurationTagRow[]) {
  const byId = new Map<number, ConfigurationTagRow>();

  for (const tag of allConfigurationTags.value) byId.set(tag.id, tag);
  for (const tag of tags) byId.set(tag.id, tag);

  allConfigurationTags.value = Array.from(byId.values()).sort((a, b) => a.name.localeCompare(b.name) || a.id - b.id);
}

const compatibleTagBindingsDirty = computed(() => {
  const original = normalizeTagIds(currentCompatibleTagBindings.value.map((binding) => binding.llm_configuration_tag_id));
  const draft = normalizeTagIds(draftCompatibleTagIds.value);
  return JSON.stringify(original) !== JSON.stringify(draft);
});

const compatibleTagBindingsPayload = computed(() => {
  const existingByTagId = new Map<number, CompatibleTagBindingRow>();
  for (const binding of currentCompatibleTagBindings.value) existingByTagId.set(binding.llm_configuration_tag_id, binding);

  return normalizeTagIds(draftCompatibleTagIds.value).map((tagId) => {
    const existing = existingByTagId.get(tagId);
    return existing ? { id: existing.id, llm_configuration_tag_id: tagId } : { llm_configuration_tag_id: tagId };
  });
});

function resetCompatibleTagBindings(bindings: CompatibleTagBindingRow[] = []) {
  currentCompatibleTagBindings.value = bindings;
  draftCompatibleTagIds.value = normalizeTagIds(bindings.map((binding) => binding.llm_configuration_tag_id));
  compatibleTagBindingsError.value = null;
}

async function loadConfigurationTags() {
  configurationTagsLoading.value = true;
  configurationTagsError.value = null;

  try {
    const qs = new URLSearchParams();
    qs.set('sort', 'name');
    qs.set('editable_only', 'true');
    qs.set('fields[llm-configuration-tags]', 'name');
    const payload = await jsonApiList('/api/ash/llm-configuration-tags', qs);
    mergeConfigurationTags(
      (payload.data || [])
        .map((resource) => {
          const id = toIntId(resource.id);
          if (!id) return null;
          const attrs = (resource.attributes || {}) as Record<string, unknown>;
          return { id, name: String(attrs.name || '').trim() } satisfies ConfigurationTagRow;
        })
        .filter((tag): tag is ConfigurationTagRow => Boolean(tag))
    );
    configurationTagsCatalogLoaded.value = true;
  } catch (error) {
    console.error(error);
    const message = error instanceof Error ? error.message : 'Failed to load tags.';
    if (message.startsWith('HTTP 403') || message.startsWith('HTTP 401')) {
      configurationTagsError.value = null;
    } else {
      configurationTagsError.value = message;
    }
    configurationTagsCatalogLoaded.value = false;
  } finally {
    configurationTagsLoading.value = false;
  }
}

function applyBotDocument(payload: JsonApiSingleResponse) {
  const includedIndex = createJsonApiIncludedIndex(payload.included);
  const root = payload.data;

  const knowledgeBlockBindingResources = relatedResources(root, 'knowledge_block_bindings', includedIndex);
  bindings.hydrate(
    knowledgeBlockBindingResources
      .map((resource) => parseKnowledgeBlockBindingItem(resource, includedIndex))
      .filter((item): item is KnowledgeBlockLinkItem => Boolean(item))
  );
  mergeKnowledgeBlocks(
    knowledgeBlockBindingResources
      .map((resource) => parseKnowledgeBlockOption(relatedResource(resource, 'knowledge_block', includedIndex)))
      .filter((block): block is KnowledgeBlock => Boolean(block))
  );

  const tagBindingResources = relatedResources(root, 'compatible_configuration_tag_bindings', includedIndex);
  mergeConfigurationTags(
    tagBindingResources
      .map((resource) => parseConfigurationTagRow(relatedResource(resource, 'llm_configuration_tag', includedIndex)))
      .filter((tag): tag is ConfigurationTagRow => Boolean(tag))
  );
  resetCompatibleTagBindings(
    tagBindingResources
      .map((resource) => parseCompatibleTagBindingRow(resource, includedIndex))
      .filter((binding): binding is CompatibleTagBindingRow => Boolean(binding))
  );
  compatibleTagBindingsLoading.value = false;
  compatibleTagBindingsError.value = null;

  const toolBindingResources = relatedResources(root, 'tool_bindings', includedIndex);
  const userToolBindingResources = relatedResources(root, 'user_tool_bindings', includedIndex);

  mergeToolLibrary(
    [...toolBindingResources, ...userToolBindingResources]
      .map((resource) => parseToolInstanceOption(relatedResource(resource, 'tool_instance', includedIndex)))
      .filter((tool): tool is ToolInstanceOption => Boolean(tool))
  );

  toolBindings.hydrate(
    toolBindingResources
      .map((resource) => parseBotToolBindingRow(resource, includedIndex))
      .filter((binding): binding is BotToolBindingRow => Boolean(binding))
  );

  userToolOverrides.hydrate(
    userToolBindingResources
      .map((resource) => parseBotUserToolBindingRow(resource, includedIndex))
      .filter((binding): binding is NonNullable<ReturnType<typeof parseBotUserToolBindingRow>> => Boolean(binding))
  );
}

const toggleCompatibleTag = (tagId: number) => {
  const next = new Set(draftCompatibleTagIds.value);
  if (next.has(tagId)) next.delete(tagId);
  else next.add(tagId);
  draftCompatibleTagIds.value = normalizeTagIds(Array.from(next));
};

const removeCompatibleTag = (tagId: number) => {
  draftCompatibleTagIds.value = draftCompatibleTagIds.value.filter((id) => id !== tagId);
};

const dirty = computed(
  () => editor.dirty.value || bindings.dirty.value || compatibleTagBindingsDirty.value || toolBindings.dirty.value
);
const saving = computed(() => editor.saving.value);
const guardDirty = computed(() => dirty.value && !saving.value);
const headerDirty = computed(() => dirty.value && !loading.value && !loadError.value);

useUnsavedChangesGuard(guardDirty);

const form = editor.form;
const errors = editor.errors;
const isNew = editor.isNew;
const loaded = editor.loaded;
const loading = editor.loading;
const loadError = editor.loadError;
const totalCount = editor.totalCount;
const positionNumber = editor.positionNumber;
const navDisabled = editor.navDisabled;
const goPrev = editor.goPrev;
const goNext = editor.goNext;
const sharedReadonly = computed(() => !isNew.value && form.can_edit === false);
const botTab = ref<'blocks' | 'firstMessages' | 'tools' | 'context' | 'configTags' | 'variables'>('blocks');
const save = async () => {
  if (saving.value) return;
  await editor.save();
};
const cancelChanges = () => {
  editor.reset();
  bindings.reset();
  resetCompatibleTagBindings(currentCompatibleTagBindings.value.map((binding) => ({ ...binding })));
  toolBindings.reset();
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
    const response = await uploadBotImage(editor.numericId.value, file);
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
    const response = await deleteBotImage(editor.numericId.value);
    form.image = response.image;
  } catch (error) {
    console.error(error);
    alert('Failed to remove image.');
  }
};

const addFirstMessage = () => {
  form.first_messages = [...(form.first_messages || []), ''];
};

const removeFirstMessage = (idx: number) => {
  const next = [...(form.first_messages || [])];
  next.splice(idx, 1);
  form.first_messages = next;
};

const moveFirstMessage = (idx: number, delta: number) => {
  const list = [...(form.first_messages || [])];
  const target = idx + delta;
  if (target < 0 || target >= list.length) return;
  const [item] = list.splice(idx, 1);
  list.splice(target, 0, item);
  form.first_messages = list;
};

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

const knowledgeBlocks = ref<KnowledgeBlock[]>([]);

function mergeKnowledgeBlocks(blocks: KnowledgeBlock[]) {
  const byId = new Map<number, KnowledgeBlock>();

  for (const block of knowledgeBlocks.value) byId.set(block.id, block);
  for (const block of blocks) byId.set(block.id, block);

  knowledgeBlocks.value = Array.from(byId.values()).sort((a, b) => a.name.localeCompare(b.name) || a.id - b.id);
}

async function loadKnowledgeBlocks() {
  try {
    const qs = new URLSearchParams();
    qs.set('sort', 'name');
    qs.set('fields[knowledge-blocks]', 'name,version,type,token_count,image');
    const payload = await jsonApiList('/api/ash/knowledge-blocks', qs);
    mergeKnowledgeBlocks(
      (payload.data || [])
        .map((resource) => parseKnowledgeBlockOption(resource))
        .filter((block): block is KnowledgeBlock => Boolean(block))
    );
  } catch (e) {
    console.warn('Failed to load knowledge blocks', e);
  }
}

const linkedBlockIds = computed(() => bindings.linkedBlockIds.value);

const blocksById = computed(() => {
  const map = new Map<number, KnowledgeBlock>();
  for (const b of knowledgeBlocks.value || []) map.set(b.id, b);
  return map;
});

const blockName = (id: number) => blocksById.value.get(id)?.name || `Block #${id}`;
const blockImage = (id: number) => blocksById.value.get(id)?.image || null;
const blockVersion = (id: number) => blocksById.value.get(id)?.version || '';

watch(
  () => editor.idParam.value,
  () => {
    compatibleTagsPickerOpen.value = false;
  }
);

const openBlockEditor = (blockId: number) => {
  const ids = linkedBlockIds.value;
  const navKey = createRecordset(ids, { returnTo: route.fullPath });
  stackNav.open({ path: `/catalogs/knowledge-blocks/${blockId}`, query: { navKey, returnTo: route.fullPath } });
};

const newBlockDraft = useKnowledgeBlockNewDraft({
  linkedBlockIds: () => linkedBlockIds.value,
  onBlocksCreated: async (createdIds) => {
    await loadKnowledgeBlocks();
    bindings.addBlocks(createdIds);
  },
  resetOn: () => editor.idParam.value,
});

const openNewBlock = newBlockDraft.openNewBlock;

watch(
  () => stack.active.value,
  (active, wasActive) => {
    if (active) return;
    if (wasActive !== true) return;
    void newBlockDraft.consumePendingNewBlockContext();
  }
);

watch(
  () => compatibleTagsPickerOpen.value,
  (open) => {
    if (!open) return;
    if (configurationTagsCatalogLoaded.value || configurationTagsLoading.value || sharedReadonly.value) return;
    void loadConfigurationTags();
  }
);

onMounted(() => {
  void loadKnowledgeBlocks();
  void loadToolLibrary();
});

const toolLibraryLoading = ref(false);
const toolLibraryError = ref<string | null>(null);
const toolLibrary = ref<ToolInstanceOption[]>([]);

function mergeToolLibrary(tools: ToolInstanceOption[]) {
  toolLibrary.value = mergeToolInstanceOptions(toolLibrary.value, tools);
}

async function loadToolLibrary() {
  toolLibraryLoading.value = true;
  toolLibraryError.value = null;

  try {
    const qs = new URLSearchParams();
    qs.set('sort', 'name');
    qs.set('fields[tool-instances]', 'name,alias,type,outlet_online,can_edit');
    const payload = await jsonApiList('/api/ash/tool-instances', qs);
    mergeToolLibrary(
      (payload.data || [])
        .map((resource) => parseToolInstanceOption(resource))
        .filter((tool): tool is ToolInstanceOption => Boolean(tool))
    );
  } catch (e) {
    console.error(e);
    toolLibraryError.value = e instanceof Error ? e.message : 'Failed to load tools.';
  } finally {
    toolLibraryLoading.value = false;
  }
}

const toolInstanceLibrary = useToolInstanceLibrary(toolLibrary);
const toolLibraryById = toolInstanceLibrary.toolLibraryById;
const ownedToolLibrary = toolInstanceLibrary.ownedToolLibrary;
const userToolOverrides = useBotUserToolOverrides({
  botId: editor.numericId,
  ownedToolLibrary,
  toolLabel: toolInstanceLibrary.toolLabel,
});

function baseToolBindingLabel(binding: BotToolBindingRow) {
  if (sharedReadonly.value && binding.sharing_mode === 'per_user') {
    return 'Connected per user';
  }

  return toolInstanceLibrary.toolLabel(binding.tool_instance_id);
}

const toolBindingLabel = (binding: BotToolBindingRow) => baseToolBindingLabel(binding);
const toolBindingIsOutlet = (binding: BotToolBindingRow) => toolInstanceLibrary.toolIsOutlet(binding.tool_instance_id);
const toolBindingIsOnline = (binding: BotToolBindingRow) => toolInstanceLibrary.toolIsOnline(binding.tool_instance_id);
const toolBindingsSaving = computed(() => saving.value);

watch(
  () => editor.numericId.value,
  (botId) => {
    if (botId) return;
    bindings.hydrate([]);
    resetCompatibleTagBindings([]);
    compatibleTagBindingsLoading.value = false;
    toolBindings.hydrate([]);
    userToolOverrides.resetForNewBot();
  },
  { immediate: true }
);

watch(
  () => editor.numericId.value,
  () => {
    userToolOverrides.syncDrafts(toolBindings.perUserBaseBindings.value);
  },
  { immediate: true }
);

watch([toolBindings.perUserBaseBindings, userToolOverrides.userToolBindings], () => {
  userToolOverrides.syncDrafts(toolBindings.perUserBaseBindings.value);
});

function addToolBinding(toolInstanceId: number, alias: string) {
  if (isNew.value || sharedReadonly.value) return false;
  return toolBindings.add(toolInstanceId, alias);
}

function removeToolBindingById(id: number) {
  const removed = toolBindings.remove(id);
  if (!removed) return;
  userToolOverrides.userToolBindings.value = userToolOverrides.userToolBindings.value.filter(
    (row) => row.alias !== removed.alias
  );
}

const shareModalOpen = ref(false);
const shareLoading = ref(false);
const shareSaving = ref(false);
const shareGroups = ref<Group[]>([]);
const sharedGroupIds = ref<number[]>([]);

const shareToolBindings = computed<BotShareToolBinding[]>(() =>
  toolBindings.sortedToolBindings.value.map((binding) => ({
    id: binding.id,
    alias: binding.alias,
    enabled: binding.enabled,
    sharing_mode: binding.sharing_mode,
    tool_instance_name: toolLibraryById.value.get(binding.tool_instance_id)?.name || '',
    tool_instance_type: toolLibraryById.value.get(binding.tool_instance_id)?.type || '',
  }))
);

async function loadShareContext() {
  if (isNew.value || sharedReadonly.value || editor.numericId.value == null) return;

  shareLoading.value = true;
  try {
    const [groupsPayload, sharePayload] = await Promise.all([
      api.get<{ groups: Group[] }>('/api/bff/me/groups'),
      api.get<ShareStateResponse>(`/api/bff/bots/${editor.numericId.value}/shares`),
    ]);

    shareGroups.value = Array.isArray(groupsPayload.groups) ? groupsPayload.groups : [];
    sharedGroupIds.value = Array.isArray(sharePayload.group_ids)
      ? sharePayload.group_ids.filter((id): id is number => typeof id === 'number')
      : [];
  } catch (error) {
    console.error(error);
    alert(error instanceof Error ? error.message : 'Failed to load sharing settings.');
  } finally {
    shareLoading.value = false;
  }
}

async function openShareModal() {
  await loadShareContext();
  shareModalOpen.value = true;
}

async function saveSharing(payload: { groupIds: number[]; toolModes: Record<string, 'shared' | 'per_user'> }) {
  if (editor.numericId.value == null) return;

  shareSaving.value = true;
  try {
    const response = await api.put<ShareStateResponse>(`/api/bff/bots/${editor.numericId.value}/shares`, {
      group_ids: payload.groupIds,
      tool_modes: payload.toolModes,
    });

    sharedGroupIds.value = Array.isArray(response.group_ids)
      ? response.group_ids.filter((id): id is number => typeof id === 'number')
      : [];
    shareModalOpen.value = false;
    await editor.load();
  } catch (error) {
    console.error(error);
    alert(error instanceof Error ? error.message : 'Failed to save sharing settings.');
  } finally {
    shareSaving.value = false;
  }
}
</script>

<style scoped>
.share-banner {
  display: flex;
  gap: 8px;
  align-items: center;
  border-color: #bfd6f6;
  background: #f5f9ff;
}
</style>
