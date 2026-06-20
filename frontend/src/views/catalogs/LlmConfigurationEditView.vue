<template>
  <div v-if="loaded" class="stack">
    <CrudHeader
      title="LLM Configuration"
      :dirty="headerDirty"
      :position="positionNumber"
      :total="totalCount"
      :navDisabled="navDisabled"
      :showDelete="!isNew && !sharedReadonly"
      :showDuplicate="!isNew"
      :saving="saving"
      @save="saveWithValidation"
      @cancel="cancelChanges"
      @close="goList"
      @create="createNew"
      @prev="goPrev"
      @next="goNext"
      @delete="remove"
      @duplicate="duplicate"
    >
      <template #extra-actions>
        <button
          v-if="!isNew && !sharedReadonly"
          class="icon-button crud-icon-button"
          type="button"
          aria-label="Share…"
          title="Share…"
          @click="openShareModal"
        >
          <SvgIcon name="share-outgoing" size="16" />
        </button>
      </template>
    </CrudHeader>

    <p v-if="loadError" class="error-text">{{ loadError }}</p>
    <div v-if="sharedReadonly" class="card share-banner">
      <strong>Shared with you.</strong> This configuration is read-only. Duplicate it to create an editable copy.
    </div>

    <fieldset class="stack" :disabled="loading || saving || Boolean(loadError)">
      <div v-if="loading" class="loading-float" aria-live="polite">Loading…</div>
      <div class="card stack">
        <div v-if="formErrors.length" class="error-text">{{ formErrors.join(' ') }}</div>

        <div class="stack">
          <label :class="{ 'field-error': errors.hasField('provider_id') }">
            Provider
            <select v-model="providerModel" class="full" :disabled="sharedReadonly" @change="errors.clearField('provider_id')">
              <option :value="''">Select a provider…</option>
              <option v-for="p in providerOptions" :key="p.id" :value="String(p.id)">
                {{ p.name }}
              </option>
            </select>
            <div v-if="errors.hasField('provider_id')" class="error-text">{{ errors.messageFor('provider_id') }}</div>
          </label>

          <label :class="{ 'field-error': errors.hasField('model_name') }">
            Model name
            <EditableCombobox
              :model-value="form.model_name"
              :options="visibleModelOptions"
              :disabled="sharedReadonly"
              toggle-label="Show model options"
              @update:modelValue="setModelName"
            />
            <div v-if="errors.hasField('model_name')" class="error-text">{{ errors.messageFor('model_name') }}</div>
            <div v-else-if="modelsLoading" class="muted small-text">Loading model options…</div>
            <div v-else-if="modelsError" class="muted small-text">Model list unavailable.</div>
          </label>

          <label :class="{ 'field-error': errors.hasField('note') }">
            Note
            <input
              v-model="form.note"
              class="full"
              placeholder="Optional"
              :disabled="sharedReadonly"
              @input="errors.clearField('note')"
            />
            <div v-if="errors.hasField('note')" class="error-text">{{ errors.messageFor('note') }}</div>
          </label>
        </div>

        <div class="tabs">
          <button
            class="tab"
            :class="{ active: configTab === 'settings' }"
            type="button"
            @click="configTab = 'settings'"
          >
            Settings
          </button>
          <button
            class="tab"
            :class="{ active: configTab === 'parameters' }"
            type="button"
            @click="configTab = 'parameters'"
          >
            Parameters
          </button>
          <button class="tab" :class="{ active: configTab === 'tags' }" type="button" @click="configTab = 'tags'">
            Tags
          </button>
          <button class="tab" :class="{ active: configTab === 'blocks' }" type="button" @click="configTab = 'blocks'">
            Blocks
          </button>
        </div>

        <div v-if="configTab === 'settings'" class="stack">
          <label :class="{ 'field-error': errors.hasField('timeout_seconds') }">
            Timeout (seconds)
            <input
              v-model.number="form.timeout_seconds"
              type="number"
              min="1"
              class="full"
              :disabled="sharedReadonly"
              @input="errors.clearField('timeout_seconds')"
            />
            <div v-if="errors.hasField('timeout_seconds')" class="error-text">
              {{ errors.messageFor('timeout_seconds') }}
            </div>
          </label>

          <label :class="{ 'field-error': errors.hasField('context_length') }">
            Context length
            <input
              v-model.number="contextLengthModel"
              type="number"
              min="1"
              class="full"
              placeholder="Auto"
              :disabled="sharedReadonly"
              @input="errors.clearField('context_length')"
            />
            <div v-if="errors.hasField('context_length')" class="error-text">
              {{ errors.messageFor('context_length') }}
            </div>
          </label>

          <label style="display: flex; align-items: center; gap: 10px">
            <input v-model="form.enabled" type="checkbox" :disabled="sharedReadonly" />
            Enabled
          </label>

          <label style="display: flex; align-items: center; gap: 10px">
            <input v-model="form.supports_cache_control" type="checkbox" :disabled="sharedReadonly" />
            Supports cache control
          </label>

          <label style="display: flex; align-items: center; gap: 10px">
            <input v-model="form.supports_image_input" type="checkbox" :disabled="sharedReadonly" />
            Supports image input
          </label>

          <label style="display: flex; align-items: center; gap: 10px">
            <input v-model="form.fix_role_alteration" type="checkbox" :disabled="sharedReadonly" />
            Fix role alteration
          </label>
        </div>

        <div v-else-if="configTab === 'parameters'" class="stack">
          <div class="flex" style="justify-content: space-between; align-items: center; gap: 10px">
            <strong>Parameters</strong>
            <button type="button" @click="resetParametersText" :disabled="saving || sharedReadonly">Reset JSON</button>
          </div>

          <JsonCodeEditor
            :model-value="parametersText"
            :error="parametersError"
            :readonly="parametersEditorReadonly"
            label="Parameters"
            placeholder="{ }"
            @update:modelValue="setParametersText"
          />
          <div v-if="parametersError" class="error-text">{{ parametersError }}</div>
          <div class="muted">This JSON is validated on input and must be an object.</div>
        </div>

        <div v-else-if="configTab === 'tags'" class="stack">
          <div class="flex" style="justify-content: space-between; align-items: center; gap: 10px">
            <strong>Tags</strong>
            <button type="button" @click="tagsPickerOpen = true" :disabled="saving || tagsLoading || sharedReadonly">
              Add tags
            </button>
          </div>

          <p v-if="tagsLoading" class="muted">Loading…</p>
          <p v-else-if="tagsError" class="error-text">{{ tagsError }}</p>

          <div v-else-if="attachedTags.length" class="list">
            <div v-for="tag in attachedTags" :key="tag.id" class="row" style="align-items: center; gap: 8px">
              <div style="font-weight: 600; min-width: 0; overflow: hidden; text-overflow: ellipsis">
                {{ tag.name }}
              </div>
              <button type="button" :disabled="saving || sharedReadonly" @click="removeTag(tag.id)">Remove</button>
            </div>
          </div>
          <p v-else class="muted">No tags.</p>

          <p v-if="tagBindingsLoading" class="muted">Loading bindings…</p>
          <p v-else-if="tagBindingsError" class="error-text">{{ tagBindingsError }}</p>
          <p v-if="tagBindingsDirty" class="muted">Tag changes will be saved when you save the configuration.</p>
        </div>

        <div v-else class="stack">
          <KnowledgeBlockLinksCard
            title="Knowledge blocks"
            :items="bindings.draft.value"
            :blockName="blockName"
            :blockImage="blockImage"
            :blockVersion="blockVersion"
            :metaText="blockMetaText"
            :addDisabled="!bindings.loaded.value || bindings.loading.value || saving || sharedReadonly"
            :newDisabled="saving || sharedReadonly"
            :openable="true"
            :readonly="!bindings.loaded.value || bindings.loading.value || saving || sharedReadonly"
            @add="openPicker"
            @new="openNewBlock"
            @open="openBlockEditor"
            @move="(item, delta) => bindings.move(item.id, delta)"
            @remove="(id) => bindings.remove(id)"
            @toggle="(item, enabled) => bindings.setEnabled(item.id, enabled)"
          >
            <template #item-secondary-actions="{ item }">
              <button
                type="button"
                class="kb-placement-toggle"
                :disabled="!bindings.loaded.value || bindings.loading.value || saving || sharedReadonly"
                :aria-label="placementButtonLabel(item)"
                :title="placementButtonLabel(item)"
                @click.stop="toggleBindingSelection(item.id)"
              >
                {{ placementButtonText(item) }}
              </button>
            </template>

            <template #note>
              <div v-if="bindings.loading.value" class="muted" style="margin-top: 6px">Loading…</div>
              <div v-else-if="bindings.error.value" class="error-text" style="margin-top: 6px">
                {{ bindings.error.value }}
              </div>
              <div v-else-if="isNew" class="muted" style="margin-top: 6px">
                Links will be saved when you save the configuration.
              </div>
            </template>
          </KnowledgeBlockLinksCard>
        </div>
      </div>
    </fieldset>

    <KnowledgeBlocksPickerModal
      v-model:open="pickerOpen"
      v-model:selected="pickerSelected"
      title="Select blocks"
      :blocks="knowledgeBlocks"
      :disabledBlockIds="linkedBlockIds"
      confirmLabel="Add"
      @confirm="addSelectedBlocks"
    />

    <LlmConfigurationTagsPickerModal
      v-model:open="tagsPickerOpen"
      title="Select tags"
      :tags="allTags"
      :selectedTagIds="draftTagIds"
      :loading="tagsLoading"
      :error="tagsError"
      @toggle="toggleTag"
    />

    <ShareWithGroupsModal
      v-model:open="shareModalOpen"
      title="Share configuration"
      :groups="shareGroups"
      :selectedGroupIds="sharedGroupIds"
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
import { api } from '@/api/client';
import CrudHeader from '@/components/CrudHeader.vue';
import EditableCombobox from '@/components/EditableCombobox.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import KnowledgeBlockLinksCard from '@/components/KnowledgeBlockLinksCard.vue';
import KnowledgeBlocksPickerModal from '@/components/KnowledgeBlocksPickerModal.vue';
import LlmConfigurationTagsPickerModal from '@/components/LlmConfigurationTagsPickerModal.vue';
import ShareWithGroupsModal from '@/components/ShareWithGroupsModal.vue';
import JsonCodeEditor from '@/features/catalogs/components/JsonCodeEditor.vue';
import { useCrudEditor } from '@/features/catalogs/model/useCrudEditor';
import { useKnowledgeBlockBindingsDraft } from '@/features/catalogs/model/useKnowledgeBlockBindingsDraft';
import { useKnowledgeBlockNewDraft } from '@/features/catalogs/model/useKnowledgeBlockNewDraft';
import { useUnsavedChangesGuard } from '@/features/catalogs/model/useUnsavedChangesGuard';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import { useLiveEntityRows } from '@/features/entities/entityChanges';
import { parseImageAsset } from '@/features/media/image';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import {
  createJsonApiIncludedIndex,
  jsonApiGet,
  jsonApiList,
  relatedResource,
  relatedResources,
  relationshipId,
  toIntId,
  type JsonApiResource,
  type JsonApiSingleResponse,
} from '@/api/jsonApi';
import type { Group, KnowledgeBlock } from '@/types/api';

type ConfigurationForm = {
  provider_id: number | null;
  model_name: string;
  note: string;
  parameters: Record<string, unknown>;
  enabled: boolean;
  timeout_seconds: number;
  context_length: number | null;
  supports_cache_control: boolean;
  supports_image_input: boolean;
  fix_role_alteration: boolean;
  can_edit: boolean;
  shared_incoming: boolean;
  shared_outgoing: boolean;
};

type ProviderOption = { id: number; name: string };
type ProviderModelOption = {
  id: string;
  label: string;
  context_length?: number | null;
  supports_image_input?: boolean | null;
};
type ConfigurationTagRow = { id: number; name: string };
type ConfigurationTagBindingRow = { id: number; llm_configuration_tag_id: number; tag_name: string };

const CONFIGURATION_DOCUMENT_INCLUDE = [
  'provider',
  'knowledge_block_bindings.knowledge_block',
  'tag_bindings.llm_configuration_tag',
].join(',');

const route = useRoute();
const stackNav = useStackNavigation();
const stack = useNavigationStack();

function defaultParameters() {
  return {};
}

function normalizeTagIds(ids: number[]) {
  return Array.from(new Set((ids || []).filter((id): id is number => typeof id === 'number' && id > 0))).sort(
    (a, b) => a - b
  );
}

function parseDefaultTagIds() {
  const raw = Array.isArray(route.query.defaultTagId) ? route.query.defaultTagId : [route.query.defaultTagId];
  return normalizeTagIds(raw.map((value) => toIntId(value as any)).filter((id): id is number => Boolean(id)));
}

function fromApi(resource: JsonApiResource): Partial<ConfigurationForm> {
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const parameters = attrs.parameters && typeof attrs.parameters === 'object' ? (attrs.parameters as any) : {};
  return {
    provider_id:
      (typeof attrs.provider_id === 'number' ? attrs.provider_id : toIntId(attrs.provider_id as any)) ??
      relationshipId(resource, 'provider'),
    model_name: String(attrs.model_name || ''),
    note: String(attrs.note || ''),
    parameters,
    enabled: typeof attrs.enabled === 'boolean' ? attrs.enabled : Boolean(attrs.enabled),
    timeout_seconds: typeof attrs.timeout_seconds === 'number' ? attrs.timeout_seconds : Number(attrs.timeout_seconds || 300),
    context_length:
      typeof attrs.context_length === 'number' ? attrs.context_length : toIntId(attrs.context_length as any),
    supports_cache_control: Boolean(attrs.supports_cache_control),
    supports_image_input: Boolean(attrs.supports_image_input),
    fix_role_alteration: Boolean(attrs.fix_role_alteration),
    can_edit: attrs.can_edit !== false,
    shared_incoming: Boolean(attrs.shared_incoming),
    shared_outgoing: Boolean(attrs.shared_outgoing),
  };
}

function configurationDocumentQuery() {
  const qs = new URLSearchParams();
  qs.set('include', CONFIGURATION_DOCUMENT_INCLUDE);
  return qs;
}

function parseProviderOption(resource: JsonApiResource | null | undefined): ProviderOption | null {
  if (!resource) return null;
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return { id, name: String(attrs.name || '').trim() };
}

function parseConfigurationTagRow(resource: JsonApiResource | null | undefined): ConfigurationTagRow | null {
  if (!resource) return null;
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return { id, name: String(attrs.name || '').trim() };
}

function parseConfigurationTagBindingRow(
  resource: JsonApiResource,
  includedIndex: ReturnType<typeof createJsonApiIncludedIndex>
): ConfigurationTagBindingRow | null {
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

function parseKnowledgeBlockOption(resource: JsonApiResource | null | undefined): KnowledgeBlock | null {
  if (!resource) return null;
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return {
    id,
    name: String(attrs.name || ''),
    image: parseImageAsset(attrs.image),
    version: typeof attrs.version === 'string' ? attrs.version : null,
    token_count: typeof attrs.token_count === 'number' ? attrs.token_count : toIntId(attrs.token_count as any),
  } satisfies KnowledgeBlock;
}

function parseKnowledgeBlockBindingItem(
  resource: JsonApiResource,
  includedIndex: ReturnType<typeof createJsonApiIncludedIndex>
) {
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
    selection: attrs.selection === 'top' ? 'top' : 'bottom',
  } as const;
}

const editor = useCrudEditor<ConfigurationForm>({
  type: 'llm-configurations',
  basePath: '/api/ash/llm-configurations',
  indexPath: '/catalogs/llm-configurations',
  editPath: (id) => `/catalogs/llm-configurations/${id}`,
  defaultForm: () => ({
    provider_id: null,
    model_name: '',
    note: '',
    parameters: defaultParameters(),
    enabled: true,
    timeout_seconds: 300,
    context_length: null,
    supports_cache_control: false,
    supports_image_input: false,
    fix_role_alteration: false,
    can_edit: true,
    shared_incoming: false,
    shared_outgoing: false,
  }),
  fromApi,
  toAttributes: (form) => ({
    provider_id: form.provider_id,
    model_name: form.model_name,
    note: form.note || null,
    parameters: form.parameters || {},
    enabled: form.enabled,
    timeout_seconds: form.timeout_seconds,
    context_length: form.context_length,
    supports_cache_control: form.supports_cache_control,
    supports_image_input: form.supports_image_input,
    fix_role_alteration: form.fix_role_alteration,
    ...(tagBindingsPayload.value === undefined ? {} : { tag_bindings: tagBindingsPayload.value }),
    ...(bindings.payload.value === undefined ? {} : { knowledge_block_bindings: bindings.payload.value }),
  }),
  normalizeForDirty: (form) => ({
    provider_id: form.provider_id,
    model_name: form.model_name,
    note: form.note,
    parameters: form.parameters,
    enabled: form.enabled,
    timeout_seconds: form.timeout_seconds,
    context_length: form.context_length,
    supports_cache_control: form.supports_cache_control,
    supports_image_input: form.supports_image_input,
    fix_role_alteration: form.fix_role_alteration,
    can_edit: form.can_edit,
    shared_incoming: form.shared_incoming,
    shared_outgoing: form.shared_outgoing,
  }),
  duplicatePath: (id) => `/api/ash/llm-configurations/${id}/duplicate`,
  documentQuery: () => configurationDocumentQuery(),
  onDocument: (payload) => {
    applyConfigurationDocument(payload);
  },
});

const bindings = useKnowledgeBlockBindingsDraft({
  selectionEnabled: true,
  defaultSelection: 'bottom',
});

const allTags = ref<ConfigurationTagRow[]>([]);
const tagsCatalogLoaded = ref(false);
const tagsLoading = ref(false);
const tagsError = ref<string | null>(null);
const tagBindingsLoading = ref(false);
const tagBindingsError = ref<string | null>(null);
const currentTagBindings = ref<ConfigurationTagBindingRow[]>([]);
const draftTagIds = ref<number[]>(parseDefaultTagIds());
const tagsPickerOpen = ref(false);

const attachedTags = computed(() => {
  const tagMap = new Map<number, ConfigurationTagRow>();
  for (const tag of allTags.value) tagMap.set(tag.id, tag);
  for (const binding of currentTagBindings.value) {
    const name = String(binding.tag_name || '').trim();
    if (!name) continue;
    tagMap.set(binding.llm_configuration_tag_id, { id: binding.llm_configuration_tag_id, name });
  }
  return draftTagIds.value.map((id) => tagMap.get(id) || { id, name: `Tag #${id}` });
});

function mergeConfigurationTags(tags: ConfigurationTagRow[]) {
  const byId = new Map<number, ConfigurationTagRow>();

  for (const tag of allTags.value) byId.set(tag.id, tag);
  for (const tag of tags) byId.set(tag.id, tag);

  allTags.value = Array.from(byId.values()).sort((a, b) => a.name.localeCompare(b.name) || a.id - b.id);
}

const tagBindingsDirty = computed(() => {
  const original = normalizeTagIds(currentTagBindings.value.map((binding) => binding.llm_configuration_tag_id));
  const draft = normalizeTagIds(draftTagIds.value);
  return JSON.stringify(original) !== JSON.stringify(draft);
});

const tagBindingsPayload = computed(() => {
  const existingByTagId = new Map<number, ConfigurationTagBindingRow>();
  for (const binding of currentTagBindings.value) existingByTagId.set(binding.llm_configuration_tag_id, binding);

  return normalizeTagIds(draftTagIds.value).map((tagId) => {
    const existing = existingByTagId.get(tagId);
    return existing ? { id: existing.id, llm_configuration_tag_id: tagId } : { llm_configuration_tag_id: tagId };
  });
});

function resetTagBindingsToDefault() {
  currentTagBindings.value = [];
  draftTagIds.value = parseDefaultTagIds();
  tagBindingsError.value = null;
}

function resetTagBindingsToLoaded(bindings: ConfigurationTagBindingRow[]) {
  currentTagBindings.value = bindings;
  draftTagIds.value = normalizeTagIds(bindings.map((binding) => binding.llm_configuration_tag_id));
  tagBindingsError.value = null;
}

async function loadConfigurationTags() {
  tagsLoading.value = true;
  tagsError.value = null;

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
    tagsCatalogLoaded.value = true;
  } catch (error) {
    console.error(error);
    const message = error instanceof Error ? error.message : 'Failed to load tags.';
    if (message.startsWith('HTTP 403') || message.startsWith('HTTP 401')) {
      tagsError.value = null;
    } else {
      tagsError.value = message;
    }
    tagsCatalogLoaded.value = false;
  } finally {
    tagsLoading.value = false;
  }
}

const toggleTag = (tagId: number) => {
  const next = new Set(draftTagIds.value);
  if (next.has(tagId)) next.delete(tagId);
  else next.add(tagId);
  draftTagIds.value = normalizeTagIds(Array.from(next));
};

const removeTag = (tagId: number) => {
  draftTagIds.value = draftTagIds.value.filter((id) => id !== tagId);
};

const dirty = computed(() => editor.dirty.value || bindings.dirty.value || tagBindingsDirty.value);
const saving = computed(() => editor.saving.value);
const guardDirty = computed(() => dirty.value && !saving.value);
const headerDirty = computed(() => dirty.value && !loading.value && !loadError.value);

useUnsavedChangesGuard(guardDirty);

const form = editor.form;
const errors = editor.errors;
const formErrors = computed(() => errors.formErrors.value);
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
const configTab = ref<'settings' | 'parameters' | 'tags' | 'blocks'>('settings');
const parametersEditorReadonly = computed(
  () => sharedReadonly.value || loading.value || saving.value || Boolean(loadError.value)
);
const save = async () => {
  if (saving.value) return;
  await editor.save();
};
const remove = editor.remove;
const duplicate = editor.duplicate;
const createNew = editor.createNew;
const goList = editor.goList;
const cancelChanges = () => {
  editor.reset();
  bindings.reset();
  resetTagBindingsToLoaded(currentTagBindings.value.map((binding) => ({ ...binding })));
  resetParametersText();
};

const providerOptions = ref<ProviderOption[]>([]);
const modelOptions = ref<ProviderModelOption[]>([]);
const modelsLoading = ref(false);
const modelsError = ref<string | null>(null);
const modelsProviderId = ref<number | null>(null);
let modelLoadSeq = 0;

function mergeProviderOptions(options: ProviderOption[]) {
  const byId = new Map<number, ProviderOption>();

  for (const option of providerOptions.value) byId.set(option.id, option);
  for (const option of options) byId.set(option.id, option);

  providerOptions.value = Array.from(byId.values()).sort((a, b) => a.name.localeCompare(b.name) || a.id - b.id);
}

const providerModel = computed({
  get: () => (form.provider_id ? String(form.provider_id) : ''),
  set: (value: string) => {
    form.provider_id = value ? Number(value) : null;
  },
});

const modelOptionsById = computed(() => {
  const map = new Map<string, ProviderModelOption>();
  for (const option of modelOptions.value) map.set(option.id, option);
  return map;
});

const visibleModelOptions = computed(() => {
  const term = form.model_name.trim().toLowerCase();
  const options = !term
    ? modelOptions.value
    : modelOptions.value.filter((option) => {
        return option.id.toLowerCase().includes(term) || option.label.toLowerCase().includes(term);
      });

  return options.slice(0, 50).map((option) => option.id);
});

function normalizeModelOptions(models: ProviderModelOption[]) {
  const byId = new Map<string, ProviderModelOption>();

  for (const model of models) {
    const id = String(model.id || '').trim();
    if (!id) continue;
    const label = String(model.label || id).trim() || id;
    byId.set(id, {
      id,
      label,
      context_length:
        typeof model.context_length === 'number' && Number.isFinite(model.context_length)
          ? model.context_length
          : null,
      supports_image_input:
        typeof model.supports_image_input === 'boolean' ? model.supports_image_input : null,
    });
  }

  return Array.from(byId.values());
}

function applySelectedModelMetadata(modelName: string) {
  const option = modelOptionsById.value.get(String(modelName || '').trim());
  if (!option) return;

  if (typeof option.context_length === 'number' && Number.isFinite(option.context_length)) {
    form.context_length = option.context_length;
    errors.clearField('context_length');
  }

  if (typeof option.supports_image_input === 'boolean') {
    form.supports_image_input = option.supports_image_input;
  }
}

function setModelName(value: string) {
  form.model_name = value;
  errors.clearField('model_name');
  applySelectedModelMetadata(value);
}

const contextLengthModel = computed({
  get: () => (typeof form.context_length === 'number' ? form.context_length : undefined),
  set: (value: number | undefined) => {
    form.context_length = typeof value === 'number' && Number.isFinite(value) ? value : null;
  },
});

async function loadProviders() {
  try {
    const qs = new URLSearchParams();
    qs.set('sort', 'name');
    qs.set('fields[llm-providers]', 'name');
    const payload = await jsonApiList('/api/ash/llm-providers', qs);
    mergeProviderOptions(
      (payload.data || [])
        .map((r) => parseProviderOption(r))
        .filter((p): p is ProviderOption => Boolean(p))
    );
  } catch (e) {
    console.warn('Failed to load providers', e);
  }
}

async function loadProviderModels(providerId: number | null) {
  const currentSeq = ++modelLoadSeq;
  modelOptions.value = [];
  modelsError.value = null;
  modelsProviderId.value = providerId;

  if (!providerId) {
    modelsLoading.value = false;
    return;
  }

  modelsLoading.value = true;

  try {
    const payload = await api.get<{ models?: ProviderModelOption[] }>(
      `/api/bff/llm-providers/${providerId}/models`,
      { showErrorBanner: false }
    );

    if (currentSeq !== modelLoadSeq) return;
    modelOptions.value = normalizeModelOptions(Array.isArray(payload.models) ? payload.models : []);
  } catch (error) {
    if (currentSeq !== modelLoadSeq) return;
    console.warn('Failed to load provider models', error);
    modelsError.value = 'Model list unavailable.';
  } finally {
    if (currentSeq === modelLoadSeq) {
      modelsLoading.value = false;
    }
  }
}

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
    qs.set('fields[knowledge-blocks]', 'name,version,token_count,image');
    const payload = await jsonApiList('/api/ash/knowledge-blocks', qs);
    mergeKnowledgeBlocks(
      (payload.data || []).map((r) => parseKnowledgeBlockOption(r)).filter((b): b is KnowledgeBlock => Boolean(b))
    );
  } catch (e) {
    console.warn('Failed to load knowledge blocks', e);
  }
}

async function fetchKnowledgeBlockOption(blockId: number) {
  try {
    const qs = new URLSearchParams();
    qs.set('fields[knowledge-blocks]', 'name,version,token_count,image');
    const payload = await jsonApiGet(`/api/ash/knowledge-blocks/${blockId}`, qs);
    return parseKnowledgeBlockOption(payload.data);
  } catch (error) {
    console.warn('Failed to refresh configuration knowledge block option.', error);
    return null;
  }
}

useLiveEntityRows(knowledgeBlocks, {
  kind: 'knowledge-block',
  getId: (row) => row.id,
  resolveRow: (change) => fetchKnowledgeBlockOption(change.id),
  compare: (a, b) => a.name.localeCompare(b.name) || a.id - b.id,
});

function applyConfigurationDocument(payload: JsonApiSingleResponse) {
  const includedIndex = createJsonApiIncludedIndex(payload.included);
  const root = payload.data;

  mergeProviderOptions(
    [parseProviderOption(relatedResource(root, 'provider', includedIndex))].filter(
      (provider): provider is ProviderOption => Boolean(provider)
    )
  );

  const tagBindingResources = relatedResources(root, 'tag_bindings', includedIndex);
  mergeConfigurationTags(
    tagBindingResources
      .map((resource) => parseConfigurationTagRow(relatedResource(resource, 'llm_configuration_tag', includedIndex)))
      .filter((tag): tag is ConfigurationTagRow => Boolean(tag))
  );
  resetTagBindingsToLoaded(
    tagBindingResources
      .map((resource) => parseConfigurationTagBindingRow(resource, includedIndex))
      .filter((binding): binding is ConfigurationTagBindingRow => Boolean(binding))
  );
  tagBindingsLoading.value = false;
  tagBindingsError.value = null;

  const knowledgeBlockBindingResources = relatedResources(root, 'knowledge_block_bindings', includedIndex);
  bindings.hydrate(
    knowledgeBlockBindingResources
      .map((resource) => parseKnowledgeBlockBindingItem(resource, includedIndex))
      .filter((item): item is NonNullable<ReturnType<typeof parseKnowledgeBlockBindingItem>> => Boolean(item))
  );
  mergeKnowledgeBlocks(
    knowledgeBlockBindingResources
      .map((resource) => parseKnowledgeBlockOption(relatedResource(resource, 'knowledge_block', includedIndex)))
      .filter((block): block is KnowledgeBlock => Boolean(block))
  );
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
const blockSelectionLabel = (selection?: 'top' | 'bottom') => (selection === 'top' ? 'Top' : 'Bottom');

const blockMetaText = (item: { block: number; sequence: number; selection?: 'top' | 'bottom' }) => {
  const version = (blockVersion(item.block) || '').trim();
  const placement = blockSelectionLabel(item.selection);
  return version ? `${placement} · order ${item.sequence} · ${version}` : `${placement} · order ${item.sequence}`;
};

const placementButtonText = (item: { selection?: 'top' | 'bottom' }) =>
  item.selection === 'top' ? '↑ Top' : '↓ Bottom';

const placementButtonLabel = (item: { selection?: 'top' | 'bottom' }) =>
  item.selection === 'top' ? 'Move block to bottom section' : 'Move block to top section';

const toggleBindingSelection = (bindingId: number) => {
  const current = bindings.draft.value.find((item) => item.id === bindingId);
  if (!current) return;
  bindings.setSelection(bindingId, current.selection === 'top' ? 'bottom' : 'top');
};

const pickerOpen = ref(false);
const pickerSelected = ref<number[]>([]);

watch(
  () => editor.idParam.value,
  () => {
    pickerOpen.value = false;
    pickerSelected.value = [];
    tagsPickerOpen.value = false;
  }
);

watch(
  () => editor.numericId.value,
  (configurationId) => {
    if (configurationId) return;
    bindings.hydrate([]);
    resetTagBindingsToDefault();
    tagBindingsLoading.value = false;
    tagBindingsError.value = null;
  },
  { immediate: true }
);

const openPicker = () => {
  pickerSelected.value = [];
  pickerOpen.value = true;
};

const addSelectedBlocks = (ids: number[]) => bindings.addBlocks(ids);

const openBlockEditor = (blockId: number) => {
  const ids = linkedBlockIds.value;
  const recordsetKey = createRecordset(ids);
  stackNav.open({ path: `/catalogs/knowledge-blocks/${blockId}`, query: { recordsetKey } });
};

const newBlockDraft = useKnowledgeBlockNewDraft({
  linkedBlockIds: () => linkedBlockIds.value,
  onBlocksCreated: async (createdIds) => {
    const createdBlocks = await Promise.all(createdIds.map((id) => fetchKnowledgeBlockOption(id)));
    mergeKnowledgeBlocks(createdBlocks.filter((block): block is KnowledgeBlock => Boolean(block)));
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

const parametersText = ref('{}\n');
const parametersError = ref<string | null>(null);

const resetParametersText = () => {
  parametersText.value = `${JSON.stringify(form.parameters || {}, null, 2)}\n`;
  parametersError.value = null;
};

const setParametersText = (value: string) => {
  parametersText.value = value;
  handleParametersInput(value);
};

const handleParametersInput = (value = parametersText.value) => {
  const text = value || '';
  try {
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      parametersError.value = 'Parameters must be a JSON object.';
      return;
    }
    form.parameters = parsed;
    parametersError.value = null;
  } catch (e) {
    parametersError.value = e instanceof Error ? e.message : 'Invalid JSON.';
  }
};

const saveWithValidation = async () => {
  if (parametersError.value) {
    alert('Fix JSON errors before saving.');
    return;
  }
  await save();
  resetParametersText();
};

watch(
  () => editor.loading.value,
  (isLoading, wasLoading) => {
    if (!wasLoading || isLoading) return;
    resetParametersText();
  }
);

watch(
  () => tagsPickerOpen.value,
  (open) => {
    if (!open) return;
    if (tagsCatalogLoaded.value || tagsLoading.value || sharedReadonly.value) return;
    void loadConfigurationTags();
  }
);

watch(
  () => form.provider_id,
  (providerId) => {
    void loadProviderModels(providerId);
  },
  { immediate: true }
);

onMounted(() => {
  void loadProviders();
  void loadKnowledgeBlocks();
});

const shareModalOpen = ref(false);
const shareLoading = ref(false);
const shareSaving = ref(false);
const shareGroups = ref<Group[]>([]);
const sharedGroupIds = ref<number[]>([]);

async function loadShareContext() {
  if (isNew.value || sharedReadonly.value || editor.numericId.value == null) return;

  shareLoading.value = true;
  try {
    const [groupsPayload, sharePayload] = await Promise.all([
      api.get<{ groups: Group[] }>('/api/bff/me/groups'),
      api.get<{ group_ids?: number[] }>(`/api/bff/llm-configurations/${editor.numericId.value}/shares`),
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

async function saveSharing(groupIds: number[]) {
  if (editor.numericId.value == null) return;

  shareSaving.value = true;
  try {
    const response = await api.put<{ group_ids?: number[] }>(
      `/api/bff/llm-configurations/${editor.numericId.value}/shares`,
      { group_ids: groupIds }
    );

    sharedGroupIds.value = Array.isArray(response.group_ids)
      ? response.group_ids.filter((id): id is number => typeof id === 'number')
      : [];
    shareModalOpen.value = false;
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
  border-color: var(--color-info-border);
  background: var(--color-info-bg);
}

.kb-placement-toggle {
  white-space: nowrap;
}

.small-text {
  margin-top: 4px;
  font-size: 0.85rem;
}
</style>
