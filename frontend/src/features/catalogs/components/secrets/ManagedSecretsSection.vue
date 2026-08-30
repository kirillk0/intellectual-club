<template>
  <section class="managed-secrets stack">
    <div class="managed-secrets__header">
      <div>
        <strong>{{ translate('Managed secrets') }}</strong>
        <p class="muted managed-secrets__hint">
          {{ translate('The model sees secret names and environment variables, but never their values.') }}
        </p>
      </div>

      <button
        v-if="!readonly"
        class="primary managed-secrets__create"
        type="button"
        :disabled="loading"
        :aria-label="translate('Create secret')"
        :title="translate('Create secret')"
        @click="openCreate"
      >
        <SvgIcon name="plus" :size="18" />
        <span>{{ translate('Create') }}</span>
      </button>
    </div>

    <p v-if="dirty" class="muted">
      {{ translate('Secret changes will be saved when you save this item.') }}
    </p>
    <p v-if="loading" class="muted">{{ translate('Loading managed secrets…') }}</p>
    <p v-if="loadError" class="error-text">{{ loadError }}</p>

    <div v-if="!loading" class="managed-secrets__table-wrap">
      <table v-if="secrets.length" class="managed-secrets__table">
        <thead>
          <tr>
            <th>{{ translate('Name') }}</th>
            <th>{{ translate('Environment variable') }}</th>
            <th v-if="!readonly" class="managed-secrets__actions-heading">{{ translate('Actions') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="secret in secrets" :key="secret.id">
            <td><div class="managed-secrets__name">{{ secret.name }}</div></td>
            <td><code>{{ secret.env_name }}</code></td>
            <td v-if="!readonly" class="managed-secrets__actions">
              <button
                  class="icon-button managed-secrets__action"
                  type="button"
                  :aria-label="translate('Edit secret')"
                  :title="translate('Edit secret')"
                  @click="openEdit(secret)"
                >
                  <SvgIcon name="edit" :size="17" />
                </button>
                <button
                  class="icon-button danger managed-secrets__action"
                  type="button"
                  :aria-label="translate('Delete secret')"
                  :title="translate('Delete secret')"
                  @click="remove(secret)"
                >
                  <SvgIcon name="delete" :size="17" />
                </button>
            </td>
          </tr>
        </tbody>
      </table>
      <p v-else class="muted">{{ translate('No managed secrets configured.') }}</p>
    </div>

    <ManagedSecretModal
      v-model:open="modalOpen"
      :secret="editingSecret"
      :saving="false"
      :error="modalError"
      @save="saveModal"
    />
  </section>
</template>

<script setup lang="ts">
import { ref } from 'vue';

import type { ManagedSecretInput } from '@/api/managedSecrets';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import type { ManagedSecretDraftItem } from '@/features/catalogs/model/useManagedSecretsState';
import ManagedSecretModal from './ManagedSecretModal.vue';
import { translate } from '@/i18n';

const props = defineProps<{
  secrets: ManagedSecretDraftItem[];
  loading: boolean;
  loadError: string | null;
  dirty?: boolean;
  readonly?: boolean;
}>();

const emit = defineEmits<{
  (event: 'update:secrets', secrets: ManagedSecretDraftItem[]): void;
}>();

const modalError = ref<string | null>(null);
const modalOpen = ref(false);
const editingSecret = ref<ManagedSecretDraftItem | null>(null);

function replaceSecrets(nextSecrets: ManagedSecretDraftItem[]) {
  emit('update:secrets', nextSecrets);
}

function openCreate() {
  editingSecret.value = null;
  modalError.value = null;
  modalOpen.value = true;
}

function openEdit(secret: ManagedSecretDraftItem) {
  editingSecret.value = secret;
  modalError.value = null;
  modalOpen.value = true;
}

function saveModal(input: ManagedSecretInput) {
  modalError.value = null;

  const duplicate = props.secrets.some(
    (secret) =>
      secret.id !== editingSecret.value?.id && secret.env_name === input.env_name
  );
  if (duplicate) {
    modalError.value = translate('Environment variable name must be unique.');
    return;
  }

  if (editingSecret.value) {
    replaceSecrets(
      props.secrets.map((secret) =>
        secret.id === editingSecret.value?.id ? { ...secret, ...input } : secret
      )
    );
  } else {
    const id = Math.min(0, ...props.secrets.map((secret) => secret.id)) - 1;
    replaceSecrets([
      ...props.secrets,
      {
        id,
        external_id: `pending-${Math.abs(id)}`,
        name: input.name,
        description: input.description,
        env_name: input.env_name,
        value: input.value,
      },
    ]);
  }

  modalOpen.value = false;
  editingSecret.value = null;
}

function remove(secret: ManagedSecretDraftItem) {
  if (!window.confirm(translate('Delete secret “{name}”?', { name: secret.name }))) return;
  replaceSecrets(props.secrets.filter((item) => item.id !== secret.id));
}
</script>

<style scoped>
.managed-secrets__header {
  align-items: flex-start;
  display: flex;
  gap: 16px;
  justify-content: space-between;
}

.managed-secrets__hint {
  margin: 4px 0 0;
}

.managed-secrets__create {
  align-items: center;
  display: inline-flex;
  flex: 0 0 auto;
  gap: 6px;
}

.managed-secrets__table-wrap {
  overflow-x: auto;
}

.managed-secrets__table {
  border-collapse: collapse;
  width: 100%;
}

.managed-secrets__table th,
.managed-secrets__table td {
  border-bottom: 1px solid var(--border);
  padding: 10px 12px;
  text-align: left;
  vertical-align: middle;
}

.managed-secrets__table th:first-child,
.managed-secrets__table td:first-child {
  padding-left: 0;
}

.managed-secrets__table th:last-child,
.managed-secrets__table td:last-child {
  padding-right: 0;
}

.managed-secrets__name {
  font-weight: 600;
}

.managed-secrets__actions-heading {
  text-align: right !important;
  width: 88px;
}

.managed-secrets__actions {
  text-align: right !important;
  white-space: nowrap;
}

.managed-secrets__action + .managed-secrets__action {
  margin-left: 4px;
}
</style>
