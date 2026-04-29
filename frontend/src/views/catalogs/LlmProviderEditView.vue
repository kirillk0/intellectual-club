<template>
  <div v-if="loaded" class="stack">
    <CrudHeader
      title="LLM Provider"
      :dirty="headerDirty"
      :position="positionNumber"
      :total="totalCount"
      :navDisabled="navDisabled"
      :showDelete="!isNew && !sharedReadonly"
      :showDuplicate="!isNew"
      :saving="saving"
      @save="save"
      @cancel="reset"
      @close="goList"
      @create="createNew"
      @prev="goPrev"
      @next="goNext"
      @delete="remove"
      @duplicate="duplicate"
    />

    <p v-if="loadError" class="error-text">{{ loadError }}</p>
    <div v-if="sharedReadonly" class="card share-banner">
      <strong>Shared with you.</strong> This provider is read-only. Duplicate it to create an editable copy.
    </div>
    <div v-if="providerTypesLoadError" class="card warning-banner">
      {{ providerTypesLoadError }}
    </div>
    <div v-if="currentProviderTypeMissing" class="card warning-banner">
      This provider type is not available in the current application build. Saving changes will fail until a
      supported type is selected.
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

        <div class="tabs">
          <button
            class="tab"
            :class="{ active: providerTab === 'settings' }"
            type="button"
            @click="providerTab = 'settings'"
          >
            Settings
          </button>
          <button
            class="tab"
            :class="{ active: providerTab === 'credentials' }"
            type="button"
            @click="providerTab = 'credentials'"
          >
            Credentials
          </button>
        </div>

        <div v-if="providerTab === 'settings'" class="stack">
          <label :class="{ 'field-error': errors.hasField('type') }">
            Type
            <select v-model="form.type" class="full" @change="errors.clearField('type')">
              <option
                v-for="providerType in providerTypeOptions"
                :key="providerType.type"
                :value="providerType.type"
                :disabled="providerType.missing"
              >
                {{ providerType.label }}
              </option>
            </select>
            <div v-if="errors.hasField('type')" class="error-text">{{ errors.messageFor('type') }}</div>
          </label>

          <label :class="{ 'field-error': errors.hasField('base_url') }">
            Base URL
            <EditableCombobox
              v-model="form.base_url"
              :options="baseUrlSuggestions"
              :placeholder="baseUrlPlaceholder"
              toggle-label="Show base URL options"
            />
            <div v-if="errors.hasField('base_url')" class="error-text">{{ errors.messageFor('base_url') }}</div>
          </label>
        </div>

        <div v-else class="stack">
          <label :class="{ 'field-error': errors.hasField('auth_method') }">
            Auth method
            <select v-model="form.auth_method" class="full" @change="errors.clearField('auth_method')">
              <option v-for="opt in authMethodOptions" :key="opt.value" :value="opt.value">
                {{ opt.label }}
              </option>
            </select>
            <div v-if="errors.hasField('auth_method')" class="error-text">
              {{ errors.messageFor('auth_method') }}
            </div>
          </label>

          <label v-if="showsApiKeyCredential" :class="{ 'field-error': errors.hasField('api_key') }">
            API Key
            <div class="flex" style="justify-content: space-between; gap: 10px; align-items: baseline">
              <div class="muted" style="font-size: 0.85rem">
                Write-only. Stored on the server and not displayed once saved.
              </div>
              <span
                class="badge"
                :class="apiKeyPresent ? '' : 'muted'"
                :title="apiKeyPresent ? 'API key is set' : 'API key is not set'"
              >
                {{ apiKeyPresent ? 'set' : 'not set' }}
              </span>
            </div>
            <div class="flex" style="gap: 8px; align-items: center">
              <input
                v-model="form.api_key"
                type="password"
                class="full"
                autocomplete="new-password"
                placeholder="Stored on server"
                @input="
                  errors.clearField('api_key');
                  clearApiKey = false;
                "
              />
              <button
                type="button"
                class="danger"
                :disabled="!apiKeyPresent || saving || loading"
                @click="markApiKeyForClear"
                title="Remove the stored API key on the server."
              >
                Clear
              </button>
            </div>
            <div v-if="errors.hasField('api_key')" class="error-text">{{ errors.messageFor('api_key') }}</div>
            <div v-if="clearApiKey" class="muted" style="margin-top: 6px">API key will be removed on save.</div>
          </label>

          <label
            v-if="showsOauthRefreshTokenCredential"
            :class="{ 'field-error': errors.hasField('oauth_refresh_token') }"
          >
            Refresh token
            <div class="flex" style="justify-content: space-between; gap: 10px; align-items: baseline">
              <div class="muted" style="font-size: 0.85rem">
                Write-only. Stored on the server and not displayed once saved.
              </div>
              <span
                class="badge"
                :class="oauthRefreshTokenPresent ? '' : 'muted'"
                :title="oauthRefreshTokenPresent ? 'Refresh token is set' : 'Refresh token is not set'"
              >
                {{ oauthRefreshTokenPresent ? 'set' : 'not set' }}
              </span>
            </div>
            <div class="flex" style="gap: 8px; align-items: center">
              <input
                v-model="form.oauth_refresh_token"
                type="password"
                class="full"
                autocomplete="new-password"
                placeholder="Stored on server"
                @input="
                  errors.clearField('oauth_refresh_token');
                  clearOauthRefreshToken = false;
                "
              />
              <button
                type="button"
                class="danger"
                :disabled="!oauthRefreshTokenPresent || saving || loading"
                @click="markOauthRefreshTokenForClear"
                title="Remove the stored refresh token on the server."
              >
                Clear
              </button>
            </div>
            <div v-if="errors.hasField('oauth_refresh_token')" class="error-text">
              {{ errors.messageFor('oauth_refresh_token') }}
            </div>
            <div v-if="clearOauthRefreshToken" class="muted" style="margin-top: 6px">
              Refresh token will be removed on save.
            </div>
          </label>
        </div>
      </div>
    </fieldset>
  </div>

  <p v-else class="muted">Loading…</p>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { api } from '@/api/client';
import CrudHeader from '@/components/CrudHeader.vue';
import EditableCombobox from '@/components/EditableCombobox.vue';
import { useCrudEditor } from '@/features/catalogs/model/useCrudEditor';
import { useUnsavedChangesGuard } from '@/features/catalogs/model/useUnsavedChangesGuard';
import { jsonApiGet, type JsonApiResource } from '@/api/jsonApi';

type ProviderForm = {
  name: string;
  type: string;
  auth_method: string;
  base_url: string;
  api_key: string;
  oauth_refresh_token: string;
  credentials_present: string[];
  can_edit: boolean;
  shared_incoming: boolean;
  shared_outgoing: boolean;
};

type ProviderAuthMethodMetadata = {
  value: string;
  label: string;
  credential?: string | null;
  required?: boolean;
};

type ProviderTypeMetadata = {
  type: string;
  label: string;
  default_auth_method: string;
  auth_methods: ProviderAuthMethodMetadata[];
  base_url_options: string[];
  default_base_url?: string | null;
  supports_model_discovery: boolean;
  missing?: boolean;
};

type ProviderTypesResponse = {
  types: ProviderTypeMetadata[];
};

function fromApi(resource: JsonApiResource): Partial<ProviderForm> {
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const credentials_present = Array.isArray(attrs.credentials_present)
    ? attrs.credentials_present.map((item) => String(item || '').trim()).filter((item) => Boolean(item))
    : [];

  return {
    name: String(attrs.name || ''),
    type: String(attrs.type || 'openrouter_chat_completion'),
    auth_method: String(attrs.auth_method || 'api_key'),
    base_url: String(attrs.base_url || ''),
    api_key: '',
    oauth_refresh_token: '',
    credentials_present,
    can_edit: attrs.can_edit !== false,
    shared_incoming: Boolean(attrs.shared_incoming),
    shared_outgoing: Boolean(attrs.shared_outgoing),
  };
}

const clearApiKey = ref(false);
const clearOauthRefreshToken = ref(false);
const providerTypes = ref<ProviderTypeMetadata[]>([]);
const providerTypesLoaded = ref(false);
const providerTypesLoadError = ref('');

const editor = useCrudEditor<ProviderForm>({
  type: 'llm-providers',
  basePath: '/api/ash/llm-providers',
  indexPath: '/catalogs/llm-providers',
  editPath: (id) => `/catalogs/llm-providers/${id}`,
  defaultForm: () => ({
    name: '',
    type: 'openrouter_chat_completion',
    auth_method: 'api_key',
    base_url: '',
    api_key: '',
    oauth_refresh_token: '',
    credentials_present: [],
    can_edit: true,
    shared_incoming: false,
    shared_outgoing: false,
  }),
  fromApi,
  toAttributes: (form) => {
    const attrs: Record<string, unknown> = {
      name: form.name,
      type: form.type,
      auth_method: form.auth_method,
      base_url: form.base_url || null,
    };
    const apiKey = form.api_key.trim();
    const refreshToken = form.oauth_refresh_token.trim();

    if (apiKey) attrs.api_key = apiKey;
    if (refreshToken) attrs.oauth_refresh_token = refreshToken;

    if (clearApiKey.value && !apiKey) attrs.api_key = null;
    if (clearOauthRefreshToken.value && !refreshToken) attrs.oauth_refresh_token = null;

    return attrs;
  },
  normalizeForDirty: (form) => ({
    name: form.name,
    type: form.type,
    auth_method: form.auth_method,
    base_url: form.base_url,
    api_key_set: Boolean(form.api_key.trim()),
    oauth_refresh_token_set: Boolean(form.oauth_refresh_token.trim()),
    clear_api_key: Boolean(clearApiKey.value),
    clear_oauth_refresh_token: Boolean(clearOauthRefreshToken.value),
  }),
  duplicatePath: (id) => `/api/ash/llm-providers/${id}/duplicate`,
});

useUnsavedChangesGuard(editor.dirty);

const form = editor.form;
const errors = editor.errors;
const isNew = editor.isNew;
const loaded = editor.loaded;
const loading = editor.loading;
const loadError = editor.loadError;
const saving = editor.saving;
const dirty = editor.dirty;
const sharedReadonly = computed(() => !isNew.value && form.can_edit === false);
const headerDirty = computed(() => dirty.value && !loading.value && !loadError.value);
const providerTab = ref<'settings' | 'credentials'>('settings');
const apiKeyPresent = computed(() => (form.credentials_present || []).includes('api_key'));
const oauthRefreshTokenPresent = computed(() =>
  (form.credentials_present || []).includes('oauth_refresh_token')
);

const providerTypesByType = computed(() => {
  const map = new Map<string, ProviderTypeMetadata>();
  for (const providerType of providerTypes.value) {
    map.set(providerType.type, providerType);
  }
  return map;
});

const currentProviderType = computed(() => providerTypesByType.value.get(String(form.type || '').trim()) || null);
const currentProviderTypeMissing = computed(
  () => loaded.value && providerTypesLoaded.value && Boolean(form.type) && !currentProviderType.value
);
const providerTypeOptions = computed(() => {
  const options = [...providerTypes.value];
  const type = String(form.type || '').trim();

  if (type && !providerTypesByType.value.has(type)) {
    options.push({
      type,
      label: `${type} (unavailable)`,
      default_auth_method: String(form.auth_method || 'api_key'),
      auth_methods: fallbackAuthMethods(),
      base_url_options: [],
      default_base_url: null,
      supports_model_discovery: false,
      missing: true,
    });
  }

  return options;
});

function fallbackAuthMethods(): ProviderAuthMethodMetadata[] {
  const method = String(form.auth_method || 'api_key').trim() || 'api_key';

  if (method === 'openai_oauth_refresh_token') {
    return [{ value: method, label: 'OpenAI OAuth (Refresh token)', credential: 'oauth_refresh_token' }];
  }

  if (method === 'api_key') {
    return [{ value: method, label: 'API key', credential: 'api_key' }];
  }

  return [{ value: method, label: method, credential: null }];
}

const authMethodOptions = computed(() => {
  const methods = currentProviderType.value?.auth_methods || fallbackAuthMethods();
  return methods.map((method) => ({ value: method.value, label: method.label }));
});

const selectedAuthMethod = computed(() => {
  const methods = currentProviderType.value?.auth_methods || fallbackAuthMethods();
  return methods.find((method) => method.value === form.auth_method) || methods[0] || null;
});
const selectedCredential = computed(() => selectedAuthMethod.value?.credential || null);
const showsApiKeyCredential = computed(() => selectedCredential.value === 'api_key');
const showsOauthRefreshTokenCredential = computed(
  () => selectedCredential.value === 'oauth_refresh_token'
);

const baseUrlSuggestions = computed(() => currentProviderType.value?.base_url_options || []);
const baseUrlPlaceholder = computed(
  () => currentProviderType.value?.default_base_url || baseUrlSuggestions.value[0] || ''
);

async function loadProviderTypes() {
  try {
    const payload = await api.get<ProviderTypesResponse>('/api/bff/llm-provider-types');
    providerTypes.value = Array.isArray(payload.types) ? payload.types : [];
    providerTypesLoaded.value = true;
    providerTypesLoadError.value = '';
  } catch (error) {
    providerTypesLoaded.value = false;
    providerTypesLoadError.value = 'Provider type metadata could not be loaded.';
    console.warn('Failed to load provider type metadata', error);
  }
}

void loadProviderTypes();

watch(
  () => form.type,
  (type) => {
    const providerType = providerTypesByType.value.get(String(type || '').trim());
    if (!providerType) return;

    if (!providerType.auth_methods.some((method) => method.value === form.auth_method)) {
      form.auth_method = providerType.default_auth_method;
    }

    if (!form.base_url && providerType.default_base_url) {
      form.base_url = providerType.default_base_url;
    }
  }
);

watch(
  () => providerTypes.value,
  () => {
    const providerType = currentProviderType.value;
    if (!providerType) return;

    if (!providerType.auth_methods.some((method) => method.value === form.auth_method)) {
      form.auth_method = providerType.default_auth_method;
    }
  }
);

watch(
  () => form.base_url,
  () => {
    errors.clearField('base_url');
  }
);

watch(
  () => form.auth_method,
  () => {
    if (selectedCredential.value === 'api_key') {
      form.oauth_refresh_token = '';
      clearOauthRefreshToken.value = false;
    } else if (selectedCredential.value === 'oauth_refresh_token') {
      form.api_key = '';
      clearApiKey.value = false;
    } else {
      form.api_key = '';
      form.oauth_refresh_token = '';
      clearApiKey.value = false;
      clearOauthRefreshToken.value = false;
    }
  }
);

const markApiKeyForClear = () => {
  clearApiKey.value = true;
  form.api_key = '';
};

const markOauthRefreshTokenForClear = () => {
  clearOauthRefreshToken.value = true;
  form.oauth_refresh_token = '';
};

const totalCount = editor.totalCount;
const positionNumber = editor.positionNumber;
const navDisabled = editor.navDisabled;
const goPrev = editor.goPrev;
const goNext = editor.goNext;

async function refreshProviderCredentialsStatus() {
  const providerId = editor.numericId.value;
  if (!providerId) return;

  try {
    const payload = await jsonApiGet(`/api/ash/llm-providers/${providerId}`);
    const patch = fromApi(payload.data);
    if (Array.isArray(patch.credentials_present)) {
      form.credentials_present = patch.credentials_present;
    }
  } catch (error) {
    console.warn('Failed to refresh provider credentials status', error);
  }
}

const save = async () => {
  await editor.save();
  clearApiKey.value = false;
  clearOauthRefreshToken.value = false;
  await refreshProviderCredentialsStatus();
};
const reset = () => {
  clearApiKey.value = false;
  clearOauthRefreshToken.value = false;
  editor.reset();
};
const remove = editor.remove;
const duplicate = editor.duplicate;
const createNew = editor.createNew;
const goList = editor.goList;
</script>

<style scoped>
.share-banner {
  display: flex;
  gap: 8px;
  align-items: center;
  border-color: #bfd6f6;
  background: #f5f9ff;
}

.warning-banner {
  border-color: #f2c46d;
  background: #fff8e8;
}
</style>
