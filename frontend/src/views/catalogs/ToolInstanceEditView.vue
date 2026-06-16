<template>
  <div v-if="loaded" class="stack">
    <CrudHeader
      title="Tool"
      :dirty="headerDirty"
      :position="positionNumber"
      :total="totalCount"
      :navDisabled="navDisabled"
      :showDelete="!isNew && !sharedReadonly"
      :showDuplicate="!isNew"
      :saving="saving"
      @save="saveWithValidation"
      @cancel="reset"
      @close="goList"
      @create="createNew"
      @prev="goPrev"
      @next="goNext"
      @delete="remove"
      @duplicate="duplicate"
    >
      <template #extra-actions>
        <button
          v-if="!isNew && supportsDiscovery && !sharedReadonly"
          class="icon-button icon-button--labeled crud-icon-button"
          type="button"
          @click="runDiscover"
          :disabled="discovering || loading || saving || dirty"
          :aria-label="discovering ? 'Discovering…' : 'Discover functions'"
          :title="dirty ? 'Save changes before discovery.' : discovering ? 'Discovering…' : 'Discover functions'"
        >
          <SvgIcon name="tool-search" size="16" />
          <span class="icon-button__label">{{ discovering ? 'Discovering…' : 'Discover functions' }}</span>
        </button>
      </template>
    </CrudHeader>

    <p v-if="loadError" class="error-text">{{ loadError }}</p>
    <div v-if="sharedReadonly" class="card share-banner">
      <strong>Shared with you.</strong> This tool is read-only. Duplicate it to create an editable copy.
    </div>

    <fieldset class="stack" :disabled="loading || saving || Boolean(loadError) || sharedReadonly">
      <div v-if="loading" class="loading-float" aria-live="polite">Loading…</div>

      <div class="card stack">
        <div v-if="formErrors.length" class="error-text">{{ formErrors.join(' ') }}</div>

        <label :class="{ 'field-error': errors.hasField('name') }">
          Name
          <input v-model="form.name" class="full" @input="handleNameInput" />
          <div v-if="errors.hasField('name')" class="error-text">{{ errors.messageFor('name') }}</div>
        </label>

        <label :class="{ 'field-error': errors.hasField('alias') }">
          Alias
          <input v-model="form.alias" class="full" @input="handleAliasInput" />
          <div v-if="errors.hasField('alias')" class="error-text">{{ errors.messageFor('alias') }}</div>
          <div class="muted" style="margin-top: 4px">Used as the model-visible tool prefix.</div>
        </label>

        <div class="tool-type-field" :class="{ 'field-error': errors.hasField('type') }">
          <div class="tool-type-field__label">Type</div>
          <ToolTypeSelect
            v-model="form.type"
            :options="toolTypes"
            :disabled="!isNew"
            :title="!isNew ? 'Tool type cannot be changed after creation.' : ''"
            @change="errors.clearField('type')"
          />
          <div v-if="errors.hasField('type')" class="error-text">{{ errors.messageFor('type') }}</div>
        </div>

        <div class="tabs">
          <button
            class="tab"
            :class="{ active: toolTab === 'settings' }"
            type="button"
            @click="toolTab = 'settings'"
          >
            Settings
          </button>
          <button
            class="tab"
            :class="{ active: toolTab === 'description' }"
            type="button"
            @click="toolTab = 'description'"
          >
            Description
            <span v-if="descriptionHasText" class="tool-tab-indicator" aria-hidden="true"></span>
          </button>
          <button
            class="tab"
            :class="{ active: toolTab === 'credentials' }"
            type="button"
            @click="toolTab = 'credentials'"
          >
            Credentials
          </button>
          <button
            class="tab"
            :class="{ active: toolTab === 'functions' }"
            type="button"
            @click="toolTab = 'functions'"
          >
            Functions
          </button>
        </div>

        <div v-if="toolTab === 'settings'" class="stack">
          <p v-if="toolTypesError" class="error-text">{{ toolTypesError }}</p>
          <p v-else-if="toolTypesLoading" class="muted">Loading tool metadata…</p>

          <div v-if="currentToolType" class="tool-type-summary muted">
            <ToolTypeBadge :type="currentToolType.type" :typeTitle="currentToolType.title" />
            <span v-if="currentToolType.description">{{ currentToolType.description }}</span>
          </div>

          <template v-if="configFields.length">
            <label
              v-for="field in configFields"
              :key="field.key"
              :class="{ 'field-error': configFieldHasError(field.key) }"
            >
              <span class="field-label-text">
                {{ fieldLabel(field.key, field.schema) }}
                <span v-if="isConfigFieldRequired(field.key)" class="required-marker" aria-hidden="true">*</span>
              </span>

              <template v-if="configWidget(field.schema) === 'knowledge-tag-select'">
                <input :value="selectedKnowledgeTagLabel(field.key)" class="full" readonly />

                <div class="flex" style="gap: 8px; margin-top: 8px">
                  <button
                    type="button"
                    :disabled="saving || loading"
                    @click="openKnowledgeTagPicker(field.key)"
                  >
                    Select
                  </button>
                  <button
                    type="button"
                    :disabled="saving || loading || !selectedKnowledgeTagId(field.key)"
                    @click="clearKnowledgeTag(field.key)"
                  >
                    Clear
                  </button>
                </div>

                <p v-if="knowledgeTagsError" class="error-text">
                  {{ knowledgeTagsError }}
                </p>
              </template>

              <template v-else>
                <select
                  v-if="Array.isArray(field.schema.enum) && field.schema.enum.length"
                  v-model="(form.config as any)[field.key]"
                  class="full"
                  @change="clearConfigFieldErrors(field.key)"
                >
                  <option v-for="opt in field.schema.enum" :key="String(opt)" :value="opt">
                    {{ String(opt) }}
                  </option>
                </select>

                <div v-else-if="field.schema.type === 'boolean'" style="margin-top: 6px">
                  <input
                    v-model="(form.config as any)[field.key]"
                    type="checkbox"
                    @change="clearConfigFieldErrors(field.key)"
                  />
                </div>

                <input
                  v-else-if="field.schema.type === 'integer' || field.schema.type === 'number'"
                  v-model.number="(form.config as any)[field.key]"
                  class="full"
                  type="number"
                  :step="field.schema.type === 'integer' ? 1 : 0.1"
                  :min="typeof field.schema.minimum === 'number' ? field.schema.minimum : undefined"
                  :max="typeof field.schema.maximum === 'number' ? field.schema.maximum : undefined"
                  @input="clearConfigFieldErrors(field.key)"
                />

                <input
                  v-else-if="field.schema.type === 'string' || !field.schema.type"
                  v-model="(form.config as any)[field.key]"
                  class="full"
                  :type="fieldInputType(field.key, field.schema)"
                  :placeholder="fieldPlaceholder(field.key, field.schema)"
                  @input="clearConfigFieldErrors(field.key)"
                />

                <div v-else class="muted" style="margin-top: 4px">
                  Unsupported field type: {{ String(field.schema.type) }}. Use Advanced JSON editor below.
                </div>
              </template>

              <div v-if="configFieldHasError(field.key)" class="error-text">
                {{ configFieldErrorMessage(field.key) }}
              </div>
              <div v-if="field.schema.description" class="muted" style="margin-top: 4px">
                {{ field.schema.description }}
              </div>
            </label>
          </template>

          <p v-else class="muted" style="margin-top: 4px">No additional settings for this tool type.</p>

          <details class="card" style="padding: 10px">
            <summary class="muted">Advanced JSON</summary>
            <div class="stack" style="gap: 10px; margin-top: 10px">
              <div class="flex" style="justify-content: space-between; align-items: center; gap: 10px">
                <strong>Config JSON</strong>
                <button type="button" @click="resetConfigText" :disabled="saving || loading">Reset JSON</button>
              </div>
              <textarea
                v-model="configText"
                class="full"
                rows="10"
                spellcheck="false"
                placeholder="{ }"
                @input="handleConfigInput"
              ></textarea>
              <div v-if="configError" class="error-text">{{ configError }}</div>
              <div class="muted">This JSON is validated on input and must be an object.</div>
            </div>
          </details>

          <label :class="{ 'field-error': errors.hasField('max_output_tokens') }">
            Max output tokens
            <input
              v-model.number="form.max_output_tokens"
              class="full"
              type="number"
              min="0"
              step="1"
              @input="errors.clearField('max_output_tokens')"
            />
            <div v-if="errors.hasField('max_output_tokens')" class="error-text">
              {{ errors.messageFor('max_output_tokens') }}
            </div>
            <div class="muted" style="margin-top: 4px">Limits tool outputs to prevent oversized responses.</div>
          </label>

          <label :class="{ 'field-error': errors.hasField('rps_limit') }">
            RPS limit
            <input
              v-model.number="form.rps_limit"
              class="full"
              type="number"
              min="0"
              step="0.1"
              placeholder="No limit"
              @input="errors.clearField('rps_limit')"
            />
            <div v-if="errors.hasField('rps_limit')" class="error-text">
              {{ errors.messageFor('rps_limit') }}
            </div>
            <div class="muted" style="margin-top: 4px">Leave empty to disable rate limiting.</div>
          </label>

          <div v-if="supportsDiscovery && form.last_discovery_error" class="error-text">
            Discovery error: {{ form.last_discovery_error }}
          </div>
          <div v-else-if="supportsDiscovery && form.last_discovered_at" class="muted" style="font-size: 0.9rem">
            Last discovered: {{ formatRelativeDateTime(form.last_discovered_at) }}
          </div>

          <div v-if="supportsDiscovery && discoverStatsText" class="muted" style="font-size: 0.9rem">
            {{ discoverStatsText }}
          </div>
        </div>

        <div v-else-if="toolTab === 'description'" class="stack">
          <label :class="{ 'field-error': errors.hasField('description') }">
            Description
            <textarea
              v-model="form.description"
              class="full"
              rows="12"
              placeholder="Describe when and how the model should use this tool."
              @input="errors.clearField('description')"
            ></textarea>
            <div v-if="errors.hasField('description')" class="error-text">{{ errors.messageFor('description') }}</div>
            <div class="muted" style="margin-top: 4px">Visible to the model when this tool is available.</div>
          </label>
        </div>

	        <div v-else-if="toolTab === 'credentials'" class="stack">
	          <p v-if="toolTypesError" class="error-text">{{ toolTypesError }}</p>
	          <p v-else-if="toolTypesLoading" class="muted">Loading tool metadata…</p>
	          <p v-else-if="!secretsFields.length" class="muted">This tool type does not require credentials.</p>

	          <template v-else>
	            <label v-if="hasAuthToggle">
	              Authentication method
	              <select v-model="authMethod" class="full" @change="authMethodTouched = true">
	                <option value="password">password</option>
                <option value="private_key">private_key</option>
              </select>
            </label>

            <label v-for="field in visibleSecretsFields" :key="field.key">
              {{ fieldLabel(field.key, field.schema) }}
              <div class="flex" style="justify-content: space-between; gap: 10px; align-items: baseline">
                <div class="muted" style="font-size: 0.85rem">
                  Write-only. Stored on the server and not displayed once saved.
                </div>
                <span
                  class="badge"
                  :class="isSecretPresent(field.key) ? '' : 'muted'"
                  :title="isSecretPresent(field.key) ? 'Credential is set' : 'Credential is not set'"
                >
                  {{ isSecretPresent(field.key) ? 'set' : 'not set' }}
                </span>
              </div>

              <div v-if="secretWidget(field.key, field.schema) === 'textarea'">
                <textarea
                  v-model="(form.secrets_patch as any)[field.key]"
                  class="full"
                  rows="8"
                  autocomplete="off"
                  spellcheck="false"
                  :placeholder="secretPlaceholder(field.key, field.schema)"
                  @input="handleSecretInput(field.key)"
                />
                <div class="flex" style="justify-content: flex-end; margin-top: 8px">
                  <button
                    type="button"
                    class="danger"
                    :disabled="(!isSecretPresent(field.key) && !Boolean((form.secrets_clear as any)[field.key])) || saving || loading"
                    @click="markSecretForClear(field.key)"
                    title="Remove the stored credential on the server."
                  >
                    Clear
                  </button>
                </div>
              </div>
              <div v-else class="flex" style="gap: 8px; align-items: center">
                <input
                  v-model="(form.secrets_patch as any)[field.key]"
                  type="password"
                  class="full"
                  autocomplete="new-password"
                  placeholder="Stored on server"
                  @input="handleSecretInput(field.key)"
                />
                <button
                  type="button"
                  class="danger"
                  :disabled="(!isSecretPresent(field.key) && !Boolean((form.secrets_clear as any)[field.key])) || saving || loading"
                  @click="markSecretForClear(field.key)"
                  title="Remove the stored credential on the server."
                >
                  Clear
                </button>
              </div>

              <div v-if="Boolean((form.secrets_clear as any)[field.key])" class="muted" style="margin-top: 6px">
                Credential will be removed on save.
              </div>

              <div v-if="field.schema.description" class="muted" style="margin-top: 4px">
                {{ field.schema.description }}
              </div>
            </label>
          </template>
        </div>

	        <div v-else class="stack">
	          <div class="flex" style="justify-content: space-between; align-items: center; gap: 10px">
	            <strong>Functions</strong>
	            <button
	              v-if="supportsDiscovery"
              type="button"
              @click="runDiscover"
              :disabled="isNew || discovering || dirty || loading || saving"
            >
	              {{ discovering ? 'Discovering…' : 'Discover' }}
	            </button>
	          </div>

	          <p v-if="toolTypesError" class="error-text">{{ toolTypesError }}</p>
	          <p v-else-if="toolTypesLoading" class="muted">Loading tool metadata…</p>

	          <p v-if="functionsMode === 'fixed'" class="muted">This tool provides fixed functions and does not use discovery.</p>
	          <p v-else-if="supportsDiscovery && isNew" class="muted">Save the tool before discovering functions.</p>
	          <p v-else-if="functionsLoading" class="muted">Loading…</p>
	          <p v-else-if="functionsError" class="error-text">{{ functionsError }}</p>

	          <div v-if="!functionsLoading && !functionsError && !(supportsDiscovery && isNew)" class="stack" style="gap: 10px">
	            <p v-if="!functions.length" class="muted">
	              {{
	                functionsMode === 'stored'
	                  ? supportsDiscovery
	                    ? 'No functions yet. Run discovery.'
	                    : 'No functions yet.'
	                  : 'Fixed functions are provided by the driver.'
	              }}
	            </p>

	            <div v-else class="stack" style="gap: 10px">
	              <div v-for="fn in functions" :key="fn.key" class="card" style="padding: 10px">
	                <div class="flex" style="justify-content: space-between; align-items: center; gap: 10px">
	                  <div style="min-width: 0">
	                    <div style="font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">
	                      {{ fn.name }}
	                    </div>
                    <div v-if="fn.description" class="muted" style="font-size: 0.85rem">
                      {{ fn.description }}
                    </div>
                    <div v-if="fn.discovered_at" class="muted" style="font-size: 0.85rem; margin-top: 4px">
                      Discovered: {{ formatRelativeDateTime(fn.discovered_at) }}
                    </div>
                  </div>

                  <label v-if="!fn.readonly" class="flex" style="gap: 6px; white-space: nowrap">
                    <input
                      type="checkbox"
                      :checked="fn.enabled"
                      :disabled="savingFunctionIds.has(fn.key)"
                      @change="toggleFunction(fn, $event)"
                    />
                    enabled
                  </label>
                  <span v-else class="badge muted" title="Built-in fixed function">fixed</span>
                </div>

                <details v-if="fn.parameters_schema" style="margin-top: 10px">
                  <summary class="muted">Schema</summary>
                  <pre class="code-block" style="white-space: pre-wrap; word-break: break-word">{{ formatJson(fn.parameters_schema) }}</pre>
                </details>
              </div>
            </div>
          </div>
        </div>
      </div>
    </fieldset>

    <KnowledgeTagsPickerModal
      v-model:open="knowledgeTagPickerOpen"
      :tags="knowledgeTags"
      :selectedTagIds="knowledgeTagPickerSelectedIds"
      :loading="knowledgeTagsLoading"
      :error="knowledgeTagsError"
      selectionMode="single"
      title="Select knowledge tag"
      @select="selectKnowledgeTag"
    />
  </div>

  <p v-else class="muted">Loading…</p>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import CrudHeader from '@/components/CrudHeader.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import KnowledgeTagsPickerModal from '@/components/KnowledgeTagsPickerModal.vue';
import { api, isHttpError } from '@/api/client';
import {
  createJsonApiIncludedIndex,
  jsonApiGet,
  jsonApiList,
  relationshipId,
  relatedResources,
  toIntId,
  type JsonApiResource,
  type JsonApiSingleResponse,
} from '@/api/jsonApi';
import { useCrudEditor } from '@/features/catalogs/model/useCrudEditor';
import { useUnsavedChangesGuard } from '@/features/catalogs/model/useUnsavedChangesGuard';
import { formatRelativeDateTime } from '@/utils/dates';
import ToolTypeBadge from '@/components/ToolTypeBadge.vue';
import ToolTypeSelect from '@/components/ToolTypeSelect.vue';

type JsonSchema = {
  type?: string;
  title?: string;
  description?: string;
  properties?: Record<string, JsonSchema>;
  required?: unknown[];
  enum?: unknown[];
  minimum?: number;
  maximum?: number;
  default?: unknown;
  format?: string;
  [key: string]: unknown;
};

type ToolDriverMeta = {
  type: string;
  title: string;
  description: string;
  functions_mode: string;
  supports_discovery: boolean;
  supports_artifacts: boolean;
  supports_handoff: boolean;
  config_schema: JsonSchema;
  secrets_schema: JsonSchema | null;
  default_config: Record<string, unknown>;
  fixed_functions: Array<{
    name: string;
    description: string;
    enabled: boolean;
    parameters_schema: unknown;
  }>;
};

type ToolInstanceForm = {
  name: string;
  description: string;
  alias: string;
  type: string;
  config: Record<string, unknown>;
  max_output_tokens: number;
  rps_limit: number | null | '';
  last_discovered_at: string;
  last_discovery_error: string;
  secrets_present: string[];
  secrets_patch: Record<string, string>;
  secrets_clear: Record<string, boolean>;
  can_edit: boolean;
  shared_incoming: boolean;
  shared_outgoing: boolean;
};

type ToolFunctionRow = {
  id: number | null;
  key: string;
  name: string;
  description: string;
  enabled: boolean;
  parameters_schema: unknown;
  discovered_at: string;
  readonly: boolean;
  fixed: boolean;
};

const TOOL_DOCUMENT_INCLUDE = 'functions';

const route = useRoute();

function normalizeString(value: unknown): string {
  return String(value ?? '').trim();
}

function normalizeObject(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  return value as Record<string, unknown>;
}

function aliasFromName(value: unknown): string {
  const base = String(value ?? '')
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, '_')
    .replace(/_+/g, '_')
    .replace(/^[_-]+|[_-]+$/g, '')
    .slice(0, 64);

  return /^[a-z]/.test(base) ? base : 'tool';
}

function parseNullableNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null;
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;

  const text = String(value).trim();
  if (!text) return null;

  const parsed = Number(text);
  return Number.isFinite(parsed) ? parsed : null;
}

function humanizeKey(key: string): string {
  const parts = String(key || '')
    .split('_')
    .map((part) => part.trim())
    .filter(Boolean);

  return parts
    .map((part) => {
      const upper = part.toUpperCase();
      if (upper === 'URL') return 'URL';
      if (upper === 'TTL') return 'TTL';
      if (upper === 'HTTP') return 'HTTP';
      if (upper === 'SSH') return 'SSH';
      if (upper === 'API') return 'API';
      if (upper === 'OCR') return 'OCR';
      return part.charAt(0).toUpperCase() + part.slice(1);
    })
    .join(' ');
}

function fieldLabel(key: string, schema: JsonSchema): string {
  const title = typeof schema.title === 'string' ? schema.title.trim() : '';
  return title || humanizeKey(key);
}

function fieldInputType(key: string, schema: JsonSchema): string {
  const format = typeof schema.format === 'string' ? schema.format : '';
  if (format === 'uri') return 'url';
  if (key.endsWith('_url') || key.endsWith('url')) return 'url';
  return 'text';
}

function fieldPlaceholder(key: string, schema: JsonSchema): string {
  const xUi = schema['x-ui'];
  if (xUi && typeof xUi === 'object') {
    const placeholder = (xUi as any).placeholder;
    if (typeof placeholder === 'string') return placeholder;
  }

  if (key.endsWith('_url') || key.endsWith('url')) return 'https://example.com';
  return '';
}

function fromApi(resource: JsonApiResource): Partial<ToolInstanceForm> {
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const config = normalizeObject(attrs.config);
  const toolType = normalizeString(attrs.type || 'mcp-http') || 'mcp-http';

  const secrets_present = Array.isArray(attrs.secrets_present)
    ? attrs.secrets_present.map((s) => normalizeString(s)).filter((s) => Boolean(s))
    : [];

  return {
    name: normalizeString(attrs.name),
    description: String(attrs.description || ''),
    alias: normalizeString(attrs.alias),
    type: toolType,
    config,
    max_output_tokens:
      typeof attrs.max_output_tokens === 'number' ? attrs.max_output_tokens : Number(attrs.max_output_tokens || 0),
    rps_limit: parseNullableNumber(attrs.rps_limit),
    last_discovered_at: normalizeString(attrs.last_discovered_at),
    last_discovery_error: normalizeString(attrs.last_discovery_error),
    secrets_present,
    secrets_patch: {},
    secrets_clear: {},
    can_edit: attrs.can_edit !== false,
    shared_incoming: Boolean(attrs.shared_incoming),
    shared_outgoing: Boolean(attrs.shared_outgoing),
  };
}

const isNewRoute = computed(() => {
  const id = route.params.id;
  return !id || String(id) === 'new';
});

const toolTypesLoading = ref(false);
const toolTypesError = ref<string | null>(null);
const toolTypes = ref<ToolDriverMeta[]>([]);
const toolTypesByType = computed<Record<string, ToolDriverMeta>>(() => {
  const out: Record<string, ToolDriverMeta> = {};
  for (const item of toolTypes.value || []) {
    if (!item || typeof item !== 'object') continue;
    if (typeof item.type !== 'string' || !item.type.trim()) continue;
    out[item.type] = item;
  }
  return out;
});

async function loadToolTypes() {
  toolTypesLoading.value = true;
  toolTypesError.value = null;

  try {
    const payload = await api.get<{ types: ToolDriverMeta[] }>('/api/bff/tools/types');
    toolTypes.value = Array.isArray(payload?.types) ? payload.types : [];
  } catch (e) {
    console.error(e);
    toolTypesError.value = e instanceof Error ? e.message : 'Failed to load tool metadata.';
    toolTypes.value = [];
  } finally {
    toolTypesLoading.value = false;
  }
}

const editor = useCrudEditor<ToolInstanceForm>({
  type: 'tool-instances',
  basePath: '/api/ash/tool-instances',
  indexPath: '/catalogs/tools',
  editPath: (id) => `/catalogs/tools/${id}`,
  defaultForm: () => ({
    name: '',
    description: '',
    alias: '',
    type: 'mcp-http',
    config: {},
    max_output_tokens: 20_000,
    rps_limit: null,
    last_discovered_at: '',
    last_discovery_error: '',
    secrets_present: [],
    secrets_patch: {},
    secrets_clear: {},
    can_edit: true,
    shared_incoming: false,
    shared_outgoing: false,
  }),
  fromApi,
  toAttributes: (form) => {
    const attrs: Record<string, unknown> = {
      name: form.name,
      description: form.description,
      alias: form.alias,
      config: normalizeObject(form.config),
      max_output_tokens: form.max_output_tokens,
      rps_limit: parseNullableNumber(form.rps_limit),
    };

    // Create requires type, update does not accept it.
    if (isNewRoute.value) attrs.type = form.type || 'mcp-http';

    const patch: Record<string, string> = {};

    for (const [key, value] of Object.entries(form.secrets_patch || {})) {
      const trimmed = String(value || '').trim();
      if (trimmed) patch[key] = trimmed;
    }

    for (const [key, value] of Object.entries(form.secrets_clear || {})) {
      if (!value) continue;
      patch[key] = '';
    }

    if (Object.keys(patch).length) attrs.secrets = patch;

    return attrs;
  },
  normalizeForDirty: (form) => ({
    name: form.name,
    description: form.description,
    alias: form.alias,
    type: form.type,
    config: form.config,
    max_output_tokens: form.max_output_tokens,
    rps_limit: parseNullableNumber(form.rps_limit),
    secrets_patch: form.secrets_patch,
    secrets_clear: form.secrets_clear,
    can_edit: form.can_edit,
    shared_incoming: form.shared_incoming,
    shared_outgoing: form.shared_outgoing,
  }),
  duplicatePath: (id) => `/api/ash/tool-instances/${id}/duplicate`,
  documentQuery: () => {
    const params = new URLSearchParams();
    params.set('include', TOOL_DOCUMENT_INCLUDE);
    params.set(
      'fields[tool-instances]',
      'name,description,alias,type,config,max_output_tokens,rps_limit,last_discovered_at,last_discovery_error,secrets_present,can_edit,shared_incoming,shared_outgoing,functions'
    );
    return params;
  },
  onDocument: (payload) => {
    applyToolDocument(payload);
  },
});

useUnsavedChangesGuard(editor.dirty);

const form = editor.form;
const errors = editor.errors;
const formErrors = computed(() => errors.formErrors.value);
const isNew = editor.isNew;
const loaded = editor.loaded;
const loading = editor.loading;
const loadError = editor.loadError;
const saving = editor.saving;
const dirty = editor.dirty;
const sharedReadonly = computed(() => !isNew.value && form.can_edit === false);

const totalCount = editor.totalCount;
const positionNumber = editor.positionNumber;
const navDisabled = editor.navDisabled;
const goPrev = editor.goPrev;
const goNext = editor.goNext;

const headerDirty = computed(() => dirty.value && !loading.value && !loadError.value);

const remove = editor.remove;
const duplicate = editor.duplicate;
const aliasTouched = ref(false);

const configText = ref('{}\n');
const configError = ref<string | null>(null);

const resetConfigText = () => {
  configText.value = `${JSON.stringify(form.config || {}, null, 2)}\n`;
  configError.value = null;
};

const handleConfigInput = () => {
  const text = configText.value || '';
  try {
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      configError.value = 'Config must be a JSON object.';
      return;
    }
    form.config = parsed;
    configError.value = null;
  } catch (e) {
    configError.value = e instanceof Error ? e.message : 'Invalid JSON.';
  }
};

const reset = () => {
  editor.reset();
  aliasTouched.value = false;
  resetConfigText();
};
const createNew = () => {
  aliasTouched.value = false;
  editor.createNew();
};
const goList = editor.goList;

const toolTab = ref<'settings' | 'description' | 'credentials' | 'functions'>('settings');
const descriptionHasText = computed(() => String(form.description || '').trim() !== '');

function handleNameInput() {
  errors.clearField('name');
  if (isNew.value && !aliasTouched.value) {
    form.alias = aliasFromName(form.name);
    errors.clearField('alias');
  }
}

function handleAliasInput() {
  aliasTouched.value = true;
  errors.clearField('alias');
}

const currentToolType = computed<ToolDriverMeta | null>(() => {
  const meta = toolTypesByType.value[String(form.type || '').trim()];
  return meta || null;
});

const functionsMode = computed(() => {
  const raw = currentToolType.value?.functions_mode;
  return typeof raw === 'string' ? raw : '';
});

const supportsDiscovery = computed(() => Boolean(currentToolType.value?.supports_discovery));

type SchemaField = { key: string; schema: JsonSchema };

function schemaFieldOrder(schema: JsonSchema): number | null {
  const xUi = schema['x-ui'];
  if (!xUi || typeof xUi !== 'object' || Array.isArray(xUi)) return null;

  const order = (xUi as any).order;
  if (typeof order === 'number' && Number.isFinite(order)) return order;

  const parsed = Number(order);
  return Number.isFinite(parsed) ? parsed : null;
}

function compareSchemaFields(a: SchemaField, b: SchemaField): number {
  const aOrder = schemaFieldOrder(a.schema);
  const bOrder = schemaFieldOrder(b.schema);

  if (aOrder !== null || bOrder !== null) {
    return (aOrder ?? Number.MAX_SAFE_INTEGER) - (bOrder ?? Number.MAX_SAFE_INTEGER) || a.key.localeCompare(b.key);
  }

  return a.key.localeCompare(b.key);
}

type KnowledgeTagRow = {
  id: number;
  name: string;
  full_name: string;
  parent_id: number | null;
};

const knowledgeTagPickerOpen = ref(false);
const knowledgeTagPickerFieldKey = ref<string | null>(null);
const knowledgeTagsLoading = ref(false);
const knowledgeTagsError = ref<string | null>(null);
const knowledgeTagsLoaded = ref(false);
const knowledgeTags = ref<KnowledgeTagRow[]>([]);

function configWidget(schema: JsonSchema): string {
  const xUi = schema['x-ui'];
  if (xUi && typeof xUi === 'object' && !Array.isArray(xUi)) {
    const widget = (xUi as any).widget;
    if (typeof widget === 'string') return widget;
  }
  return '';
}

function parseKnowledgeTagRow(resource: JsonApiResource): KnowledgeTagRow | null {
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

async function loadKnowledgeTags() {
  if (knowledgeTagsLoading.value || knowledgeTagsLoaded.value) return;
  knowledgeTagsLoading.value = true;
  knowledgeTagsError.value = null;

  try {
    const params = new URLSearchParams();
    params.set('sort', 'full_name');
    const payload = await jsonApiList('/api/ash/knowledge-tags', params);
    knowledgeTags.value = (payload.data || [])
      .map(parseKnowledgeTagRow)
      .filter((tag): tag is KnowledgeTagRow => Boolean(tag));
    knowledgeTagsLoaded.value = true;
  } catch (e) {
    console.error(e);
    knowledgeTagsError.value = e instanceof Error ? e.message : 'Failed to load knowledge tags.';
  } finally {
    knowledgeTagsLoading.value = false;
  }
}

function selectedKnowledgeTagId(fieldKey: string): number | null {
  return toIntId((form.config as any)[fieldKey] as any) ?? null;
}

function selectedKnowledgeTagLabel(fieldKey: string): string {
  const id = selectedKnowledgeTagId(fieldKey);
  if (!id) return 'No tag selected';

  const tag = knowledgeTags.value.find((item) => item.id === id);
  if (!tag) return `Tag #${id}`;

  const label = tag.full_name || tag.name;
  return label || `Tag #${id}`;
}

const knowledgeTagPickerSelectedIds = computed(() => {
  const fieldKey = knowledgeTagPickerFieldKey.value;
  if (!fieldKey) return [];
  const id = selectedKnowledgeTagId(fieldKey);
  return id ? [id] : [];
});

async function openKnowledgeTagPicker(fieldKey: string) {
  knowledgeTagPickerFieldKey.value = fieldKey;
  knowledgeTagPickerOpen.value = true;
  await loadKnowledgeTags();
}

function selectKnowledgeTag(tagId: number) {
  const fieldKey = knowledgeTagPickerFieldKey.value;
  if (!fieldKey) return;
  (form.config as any)[fieldKey] = tagId;
  clearConfigFieldErrors(fieldKey);
  knowledgeTagPickerOpen.value = false;
}

function clearKnowledgeTag(fieldKey: string) {
  delete (form.config as any)[fieldKey];
  clearConfigFieldErrors(fieldKey);
}

const configFields = computed<SchemaField[]>(() => {
  const schema = currentToolType.value?.config_schema;
  const props =
    schema && typeof schema === 'object' && !Array.isArray(schema)
      ? (schema.properties as Record<string, unknown> | undefined)
      : undefined;

  if (!props || typeof props !== 'object' || Array.isArray(props)) return [];

  return Object.entries(props)
    .map(([key, raw]) => ({
      key: String(key),
      schema: (raw && typeof raw === 'object' ? raw : {}) as JsonSchema,
    }))
    .filter((f) => Boolean(f.key.trim()))
    .sort(compareSchemaFields);
});

watch(
  () =>
    configFields.value
      .filter((field) => configWidget(field.schema) === 'knowledge-tag-select')
      .map((field) => selectedKnowledgeTagId(field.key))
      .filter((id): id is number => typeof id === 'number'),
  (ids) => {
    if (!ids.length || sharedReadonly.value) return;
    void loadKnowledgeTags();
  },
  { immediate: true }
);

const secretsFields = computed<SchemaField[]>(() => {
  const schema = currentToolType.value?.secrets_schema;
  const props =
    schema && typeof schema === 'object' && !Array.isArray(schema)
      ? (schema.properties as Record<string, unknown> | undefined)
      : undefined;

  if (!props || typeof props !== 'object' || Array.isArray(props)) return [];

  return Object.entries(props)
    .map(([key, raw]) => ({
      key: String(key),
      schema: (raw && typeof raw === 'object' ? raw : {}) as JsonSchema,
    }))
    .filter((f) => Boolean(f.key.trim()))
    .sort(compareSchemaFields);
});

const requiredConfigKeys = computed(() => {
  const schema = currentToolType.value?.config_schema;
  const required = Array.isArray(schema?.required) ? schema.required : [];
  return new Set(required.map((value) => String(value || '').trim()).filter(Boolean));
});

function isConfigFieldRequired(fieldKey: string): boolean {
  return requiredConfigKeys.value.has(String(fieldKey || '').trim());
}

const hasAuthToggle = computed(() => {
  const keys = new Set(secretsFields.value.map((f) => f.key));
  return keys.has('password') && keys.has('private_key') && keys.size === 2;
});

const authMethod = ref<'password' | 'private_key'>('password');
const authMethodTouched = ref(false);

const visibleSecretsFields = computed(() => {
  if (!hasAuthToggle.value) return secretsFields.value;
  return secretsFields.value.filter((f) => f.key === authMethod.value);
});

function configErrorKeys(fieldKey: string): string[] {
  const key = String(fieldKey || '').trim();
  if (!key) return [];
  return [`config/${key}`, `config.${key}`, key];
}

function configFieldHasError(fieldKey: string): boolean {
  return configErrorKeys(fieldKey).some((k) => errors.hasField(k));
}

function configFieldErrorMessage(fieldKey: string): string {
  for (const k of configErrorKeys(fieldKey)) {
    if (errors.hasField(k)) return errors.messageFor(k);
  }
  return '';
}

function clearConfigFieldErrors(fieldKey: string) {
  for (const k of configErrorKeys(fieldKey)) errors.clearField(k);
  errors.clearField('config');
}

function requiredConfigValuePresent(value: unknown): boolean {
  if (typeof value === 'string') return value.trim() !== '';
  if (typeof value === 'number') return Number.isFinite(value);
  if (typeof value === 'boolean') return true;
  if (Array.isArray(value)) return value.length > 0;
  if (value && typeof value === 'object') return true;
  return false;
}

function validateRequiredConfigFields(): boolean {
  let valid = true;

  for (const field of configFields.value) {
    if (!isConfigFieldRequired(field.key)) continue;
    clearConfigFieldErrors(field.key);

    if (requiredConfigValuePresent((form.config as any)[field.key])) continue;

    errors.setField(`config/${field.key}`, `${fieldLabel(field.key, field.schema)} is required.`);
    valid = false;
  }

  if (!valid) toolTab.value = 'settings';
  return valid;
}

function isSecretPresent(secretKey: string): boolean {
  const key = String(secretKey || '').trim();
  if (!key) return false;
  return (form.secrets_present || []).includes(key);
}

function handleSecretInput(secretKey: string) {
  const key = String(secretKey || '').trim();
  if (!key) return;
  (form.secrets_clear as any)[key] = false;
}

function markSecretForClear(secretKey: string) {
  const key = String(secretKey || '').trim();
  if (!key) return;
  (form.secrets_clear as any)[key] = true;
  (form.secrets_patch as any)[key] = '';
}

watch(
  [() => hasAuthToggle.value, () => form.secrets_present],
  ([hasToggle]) => {
    if (!hasToggle) return;
    authMethod.value = isSecretPresent('private_key') ? 'private_key' : 'password';
    authMethodTouched.value = false;
  },
  { immediate: true }
);

watch(
  () => authMethod.value,
  (method, prev) => {
    if (!hasAuthToggle.value) return;
    if (method === prev) return;
    if (!authMethodTouched.value) return;

    const selected = method;
    const other = method === 'password' ? 'private_key' : 'password';

    (form.secrets_clear as any)[selected] = false;

    if (isSecretPresent(other)) {
      markSecretForClear(other);
    } else {
      (form.secrets_patch as any)[other] = '';
      (form.secrets_clear as any)[other] = false;
    }
  }
);

watch(
  () => errors.fieldErrors.value,
  (fieldErrors) => {
    if (fieldErrors.description?.length) toolTab.value = 'description';
  }
);

function secretWidget(secretKey: string, schema: JsonSchema): 'textarea' | 'password' {
  const key = String(secretKey || '').trim();
  const xUi = schema['x-ui'];
  if (xUi && typeof xUi === 'object') {
    const widget = (xUi as any).widget;
    if (widget === 'textarea') return 'textarea';
  }
  if (key.includes('private_key')) return 'textarea';
  return 'password';
}

function secretPlaceholder(secretKey: string, schema: JsonSchema): string {
  const xUi = schema['x-ui'];
  if (xUi && typeof xUi === 'object') {
    const placeholder = (xUi as any).placeholder;
    if (typeof placeholder === 'string') return placeholder;
  }

  const key = String(secretKey || '').trim();
  if (key.includes('private_key')) return '-----BEGIN OPENSSH PRIVATE KEY-----';
  return '';
}

function mergeConfigDefaults(toolType: string, config: Record<string, unknown>): Record<string, unknown> {
  const meta = toolTypesByType.value[String(toolType || '').trim()];
  const defaults = meta ? normalizeObject(meta.default_config) : {};
  const current = normalizeObject(config);
  return { ...defaults, ...current };
}

function syncDefaultsForFormAndBase() {
  const formType = String(form.type || '').trim();
  const baseType = String((editor.base.value as any)?.type || '').trim();

  if (formType) {
    form.config = mergeConfigDefaults(formType, normalizeObject(form.config));
  }

  if (baseType) {
    (editor.base.value as any).config = mergeConfigDefaults(
      baseType,
      normalizeObject((editor.base.value as any).config)
    );
  }
}

const discovering = ref(false);
const discoverStats = ref<{ created: number; updated: number; deleted: number; total: number } | null>(null);

const discoverStatsText = computed(() => {
  const stats = discoverStats.value;
  if (!stats) return '';
  return `Discovery sync: total=${stats.total}, created=${stats.created}, updated=${stats.updated}, deleted=${stats.deleted}.`;
});

function formatJson(value: unknown): string {
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function parseFunctionRow(resource: JsonApiResource): ToolFunctionRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const name = String(attrs.name || '').trim();

  return {
    id,
    key: `stored:${id}`,
    name,
    description: String(attrs.description || '').trim(),
    enabled: Boolean(attrs.enabled),
    parameters_schema: attrs.parameters_schema,
    discovered_at: String(attrs.discovered_at || '').trim(),
    readonly: false,
    fixed: false,
  };
}

const functionsLoading = ref(false);
const functionsError = ref<string | null>(null);
const functions = ref<ToolFunctionRow[]>([]);
const persistedFunctionRows = ref<ToolFunctionRow[]>([]);
const savingFunctionIds = ref(new Set<string>());

function setFixedFunctions() {
  const fixed = currentToolType.value?.fixed_functions || [];
  const overrides = new Map(persistedFunctionRows.value.map((fn) => [fn.name, fn]));

  functions.value = (fixed || []).map((fn, index) => ({
    id: overrides.get(String(fn.name || '').trim())?.id ?? null,
    key: `fixed:${String(fn.name || '').trim() || index}`,
    name: String(fn.name || '').trim(),
    description: String(fn.description || '').trim(),
    enabled: overrides.get(String(fn.name || '').trim())?.enabled ?? Boolean(fn.enabled),
    parameters_schema: fn.parameters_schema,
    discovered_at: overrides.get(String(fn.name || '').trim())?.discovered_at ?? '',
    readonly: false,
    fixed: true,
  }));
  functionsError.value = null;
  functionsLoading.value = false;
}

function applyToolDocument(payload: JsonApiSingleResponse) {
  const includedIndex = createJsonApiIncludedIndex(payload.included);
  const root = payload.data;
  persistedFunctionRows.value = relatedResources(root, 'functions', includedIndex)
    .map(parseFunctionRow)
    .filter((row): row is ToolFunctionRow => Boolean(row));

  if (functionsMode.value === 'fixed') {
    setFixedFunctions();
    return;
  }

  functions.value = persistedFunctionRows.value;
  functionsError.value = null;
  functionsLoading.value = false;
}

watch(
  () => [editor.numericId.value, form.type, isNew.value] as const,
  (current, previous) => {
    const [toolId, toolType, isNewRoute] = current;
    const [prevToolId, prevToolType, prevIsNewRoute] = previous || [];

    const recordChanged = toolId !== prevToolId || isNewRoute !== prevIsNewRoute;
    const newToolTypeChanged = isNewRoute && toolType !== prevToolType;

    if (!recordChanged && !newToolTypeChanged) return;

    syncDefaultsForFormAndBase();
    discoverStats.value = null;
    functions.value = [];
    persistedFunctionRows.value = [];
    form.secrets_patch = {};
    form.secrets_clear = {};
    authMethodTouched.value = false;
    configError.value = null;
    resetConfigText();

    if (functionsMode.value === 'fixed') {
      setFixedFunctions();
      return;
    }

    if (!editor.numericId.value) {
      functions.value = [];
    }

    functionsError.value = null;
    functionsLoading.value = false;
  },
  { immediate: true }
);

async function refreshToolMeta() {
  const toolId = editor.numericId.value;
  if (!toolId) return;

  try {
    const payload = await jsonApiGet(`/api/ash/tool-instances/${toolId}`);
    const patch = fromApi(payload.data);
    if (typeof patch.last_discovered_at === 'string') form.last_discovered_at = patch.last_discovered_at;
    if (typeof patch.last_discovery_error === 'string') form.last_discovery_error = patch.last_discovery_error;
    if (Array.isArray(patch.secrets_present)) {
      form.secrets_present = patch.secrets_present;
    }
  } catch (e) {
    console.warn('Failed to refresh tool metadata', e);
  }
}

async function runDiscover() {
  const toolId = editor.numericId.value;
  if (!toolId) return;
  if (!supportsDiscovery.value) return;
  if (discovering.value) return;

  discovering.value = true;
  discoverStats.value = null;

  try {
    const payload = await api.post<{
      tool_instance_id: number;
      created: number;
      updated: number;
      deleted: number;
      total: number;
      functions: Array<{ id: number }>;
    }>(`/api/bff/tools/${toolId}/discover`, {});

    discoverStats.value = {
      created: Number(payload.created || 0),
      updated: Number(payload.updated || 0),
      deleted: Number(payload.deleted || 0),
      total: Number(payload.total || 0),
    };

    await editor.load();
  } catch (e) {
    console.error(e);
    const message =
      isHttpError(e) && e.bodyJson && typeof (e.bodyJson as any)?.error === 'string'
        ? String((e.bodyJson as any).error)
        : e instanceof Error
          ? e.message
          : 'Discovery failed.';

    form.last_discovery_error = message;
  } finally {
    discovering.value = false;
  }
}

async function toggleFunction(fn: ToolFunctionRow, event: Event) {
  const target = event.target as HTMLInputElement | null;
  if (!target) return;
  const nextEnabled = Boolean(target.checked);

  if (savingFunctionIds.value.has(fn.key)) return;
  savingFunctionIds.value = new Set([...savingFunctionIds.value, fn.key]);

  try {
    const payload = fn.fixed
      ? await api.patch<{ id?: number; enabled?: boolean; discovered_at?: string }>(
          `/api/bff/tools/${editor.numericId.value}/fixed-functions/${encodeURIComponent(fn.name)}`,
          {
            enabled: nextEnabled,
          }
        )
      : await api.patch<{ id?: number; enabled?: boolean; discovered_at?: string }>(`/api/bff/tool-functions/${fn.id}`, {
          enabled: nextEnabled,
        });

    const persistedEnabled = typeof payload?.enabled === 'boolean' ? payload.enabled : nextEnabled;
    functions.value = functions.value.map((row) =>
      row.key === fn.key
        ? {
            ...row,
            id: typeof payload?.id === 'number' ? payload.id : row.id,
            enabled: persistedEnabled,
            discovered_at: typeof payload?.discovered_at === 'string' ? payload.discovered_at : row.discovered_at,
          }
        : row
    );
    persistedFunctionRows.value = functions.value
      .filter((row) => typeof row.id === 'number')
      .map((row) => ({ ...row, fixed: false, key: `stored:${row.id}` }));
  } catch (e) {
    console.error(e);
    alert('Failed to update function.');
  } finally {
    const next = new Set(savingFunctionIds.value);
    next.delete(fn.key);
    savingFunctionIds.value = next;
  }
}

const saveWithValidation = async () => {
  if (configError.value) {
    alert('Fix JSON errors before saving.');
    return;
  }

  if (!validateRequiredConfigFields()) return;

  await editor.save();
  await refreshToolMeta();
  editor.base.value = JSON.parse(JSON.stringify(form)) as ToolInstanceForm;
  resetConfigText();
};

watch(
  () => editor.loading.value,
  (isLoading, wasLoading) => {
    if (!wasLoading || isLoading) return;
    syncDefaultsForFormAndBase();
    resetConfigText();
  }
);

watch(
  () => toolTypes.value,
  () => {
    syncDefaultsForFormAndBase();
    resetConfigText();

    if (functionsMode.value === 'fixed') {
      setFixedFunctions();
    }
  }
);

onMounted(() => {
  loadToolTypes();
});

</script>

<style scoped>
.field-label-text {
  display: inline-flex;
  gap: 3px;
  align-items: baseline;
}

.tool-type-field {
  color: var(--color-text-muted);
  font-size: 0.9rem;
}

.tool-type-field__label {
  margin-bottom: 2px;
}

.field-error :deep(.tool-type-select__trigger) {
  border-color: var(--color-danger);
  box-shadow: 0 0 0 1px color-mix(in srgb, var(--color-danger) 22%, transparent);
}

.required-marker {
  color: var(--color-danger);
  font-weight: 700;
}

.share-banner {
  display: flex;
  gap: 8px;
  align-items: center;
  border-color: var(--color-info-border);
  background: var(--color-info-bg);
}

.tool-tab-indicator {
  display: inline-block;
  width: 6px;
  height: 6px;
  margin-left: 6px;
  border-radius: 50%;
  background: currentColor;
  vertical-align: middle;
}

.tool-type-summary {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
  margin-top: 4px;
}

.tool-type-summary > span:last-child {
  min-width: 0;
}
</style>
