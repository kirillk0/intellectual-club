<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Administration</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <button class="primary" type="button" :disabled="!dirty || saving || loading" @click="save">
            {{ saving ? 'Saving…' : 'Save' }}
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <AdministrationNav />

    <p v-if="loading" class="muted">Loading…</p>
    <p v-else-if="loadError" class="error-text">{{ loadError }}</p>

    <section v-else class="card stack">
      <div class="flex web-push-settings-header">
        <h3 style="margin: 0">Web Push Settings</h3>
        <span class="badge" :class="{ success: form.enabled, danger: !form.enabled }">
          {{ form.enabled ? 'Enabled' : 'Disabled' }}
        </span>
      </div>

      <p v-if="formError" class="error-text">{{ formError }}</p>

      <label class="web-push-settings-toggle">
        <input v-model="form.enabled" type="checkbox" :disabled="saving || regenerating" />
        Enabled
      </label>

      <label>
        Public origin
        <input
          v-model="form.public_origin"
          class="full"
          type="url"
          placeholder="https://example.com"
          :disabled="saving || regenerating"
        />
      </label>

      <label>
        VAPID subject
        <input
          v-model="form.vapid_subject"
          class="full"
          type="text"
          placeholder="mailto:admin@example.com"
          :disabled="saving || regenerating"
        />
      </label>

      <label>
        VAPID public key
        <textarea
          class="full web-push-public-key"
          :value="settings?.vapid_public_key || ''"
          rows="3"
          readonly
        ></textarea>
      </label>

      <div class="grid-2 web-push-settings-details">
        <div>
          <div class="muted">Key revision</div>
          <strong>{{ settings?.key_revision || 0 }}</strong>
        </div>
        <div>
          <div class="muted">Updated:</div>
          <strong>{{ updatedLabel }}</strong>
        </div>
      </div>

      <p class="muted">
        Private VAPID key is stored on the server and is never returned to the browser.
      </p>
      <p class="muted">
        Public origin must be an https origin in production, or localhost over http for local development.
      </p>

      <div class="flex web-push-settings-actions">
        <button
          type="button"
          class="danger"
          :disabled="saving || regenerating || loading"
          @click="regenerateKeys"
        >
          {{ regenerating ? 'Regenerating…' : 'Regenerate keys' }}
        </button>
      </div>
    </section>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue';
import AdministrationNav from '@/components/AdministrationNav.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { api, isHttpError } from '@/api/client';
import { formatRelativeDateTime } from '@/utils/dates';
import type { WebPushSettings } from '@/types/api';

type SettingsResponse = {
  settings: WebPushSettings;
};

type WebPushSettingsForm = {
  enabled: boolean;
  public_origin: string;
  vapid_subject: string;
};

const loading = ref(false);
const saving = ref(false);
const regenerating = ref(false);
const loadError = ref('');
const formError = ref('');
const settings = ref<WebPushSettings | null>(null);
const baseSnapshot = ref('');

const form = reactive<WebPushSettingsForm>({
  enabled: false,
  public_origin: '',
  vapid_subject: '',
});

const snapshotForm = () =>
  JSON.stringify({
    enabled: Boolean(form.enabled),
    public_origin: form.public_origin.trim(),
    vapid_subject: form.vapid_subject.trim(),
  });

const dirty = computed(() => snapshotForm() !== baseSnapshot.value);

const updatedLabel = computed(() => {
  const updated = settings.value?.updated_at;
  return formatRelativeDateTime(updated) || updated || 'Not saved';
});

const applySettings = (next: WebPushSettings) => {
  settings.value = next;
  form.enabled = Boolean(next.enabled);
  form.public_origin = next.public_origin || '';
  form.vapid_subject = next.vapid_subject || '';
  baseSnapshot.value = snapshotForm();
};

const errorMessage = (error: unknown, fallback: string) => {
  if (!isHttpError(error)) return error instanceof Error ? error.message : fallback;

  const body = error.bodyJson;
  if (body && typeof body === 'object') {
    const detail = (body as { detail?: unknown; error?: unknown }).detail;
    const directError = (body as { detail?: unknown; error?: unknown }).error;

    if (typeof detail === 'string' && detail.trim()) return detail.trim();
    if (typeof directError === 'string' && directError.trim()) return directError.trim();
  }

  return error.message || fallback;
};

const loadSettings = async () => {
  loading.value = true;
  loadError.value = '';
  formError.value = '';

  try {
    const payload = await api.get<SettingsResponse>('/api/bff/admin/web-push-settings');
    applySettings(payload.settings);
  } catch (error) {
    console.error(error);
    loadError.value = errorMessage(error, 'Failed to load Web Push settings.');
  } finally {
    loading.value = false;
  }
};

const save = async () => {
  if (saving.value || !dirty.value) return;
  saving.value = true;
  formError.value = '';

  try {
    const payload = await api.patch<SettingsResponse>('/api/bff/admin/web-push-settings', {
      enabled: form.enabled,
      public_origin: form.public_origin.trim() || null,
      vapid_subject: form.vapid_subject.trim() || null,
    });
    applySettings(payload.settings);
  } catch (error) {
    console.error(error);
    formError.value = errorMessage(error, 'Failed to save Web Push settings.');
  } finally {
    saving.value = false;
  }
};

const regenerateKeys = async () => {
  if (regenerating.value) return;
  if (!window.confirm('Regenerate VAPID keys? Existing browser subscriptions will need to subscribe again.')) return;

  regenerating.value = true;
  formError.value = '';

  try {
    const payload = await api.post<SettingsResponse>(
      '/api/bff/admin/web-push-settings/regenerate-keys',
      {}
    );
    applySettings(payload.settings);
    window.alert('Web Push keys regenerated. Existing browser subscriptions must be renewed.');
  } catch (error) {
    console.error(error);
    formError.value = errorMessage(error, 'Failed to regenerate Web Push keys.');
  } finally {
    regenerating.value = false;
  }
};

onMounted(() => {
  loadSettings();
});
</script>

<style scoped>
.web-push-settings-header,
.web-push-settings-actions {
  justify-content: space-between;
}

.web-push-settings-toggle {
  display: inline-flex;
  align-items: center;
  gap: 8px;
}

.web-push-public-key {
  min-height: 82px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', monospace;
  word-break: break-all;
}

.web-push-settings-details {
  align-items: start;
}
</style>
