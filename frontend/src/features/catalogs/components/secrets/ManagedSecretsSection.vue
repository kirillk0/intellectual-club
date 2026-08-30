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
        :disabled="isNew || loading || busy"
        :aria-label="translate('Create secret')"
        :title="isNew ? translate('Save this item before creating secrets.') : translate('Create secret')"
        @click="openCreate"
      >
        <SvgIcon name="plus" :size="18" />
        <span>{{ translate('Create') }}</span>
      </button>
    </div>

    <p v-if="isNew" class="muted">{{ translate('Save this item before creating secrets.') }}</p>
    <p v-else-if="loading" class="muted">{{ translate('Loading managed secrets…') }}</p>
    <p v-if="loadError || actionError" class="error-text">{{ loadError || actionError }}</p>

    <div v-if="!isNew && !loading" class="managed-secrets__table-wrap">
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
                  :disabled="busy"
                  :aria-label="translate('Edit secret')"
                  :title="translate('Edit secret')"
                  @click="openEdit(secret)"
                >
                  <SvgIcon name="edit" :size="17" />
                </button>
                <button
                  class="icon-button danger managed-secrets__action"
                  type="button"
                  :disabled="busy"
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
      :saving="savingModal"
      :error="modalError"
      @save="saveModal"
    />
  </section>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';

import { getApiErrorMessage } from '@/api/client';
import {
  createManagedSecret,
  deleteManagedSecret,
  updateManagedSecret,
  type ManagedSecretAttachment,
  type ManagedSecretInput,
  type SecretAttachmentParent,
} from '@/api/managedSecrets';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import ManagedSecretModal from './ManagedSecretModal.vue';
import { translate } from '@/i18n';

const props = defineProps<{
  parent: SecretAttachmentParent;
  parentId: number | null | undefined;
  secrets: ManagedSecretAttachment[];
  loading: boolean;
  loadError: string | null;
  readonly?: boolean;
}>();

const emit = defineEmits<{
  (event: 'update:secrets', secrets: ManagedSecretAttachment[]): void;
}>();

const busy = ref(false);
const savingModal = ref(false);
const actionError = ref<string | null>(null);
const modalError = ref<string | null>(null);
const modalOpen = ref(false);
const editingSecret = ref<ManagedSecretAttachment | null>(null);

const isNew = computed(() => !props.parentId || props.parentId <= 0);

function replaceSecrets(nextSecrets: ManagedSecretAttachment[]) {
  emit('update:secrets', nextSecrets);
}

watch(
  () => [props.parent, props.parentId] as const,
  () => {
    actionError.value = null;
    modalError.value = null;
  }
);

function openCreate() {
  editingSecret.value = null;
  modalError.value = null;
  modalOpen.value = true;
}

function openEdit(secret: ManagedSecretAttachment) {
  editingSecret.value = secret;
  modalError.value = null;
  modalOpen.value = true;
}

async function saveModal(input: ManagedSecretInput) {
  if (!props.parentId) return;
  savingModal.value = true;
  modalError.value = null;

  try {
    const response = editingSecret.value
      ? await updateManagedSecret(
          props.parent,
          props.parentId,
          editingSecret.value.id,
          input
        )
      : await createManagedSecret(props.parent, props.parentId, {
          ...input,
          value: input.value || '',
        });

    replaceSecrets(response.secrets || []);
    modalOpen.value = false;
    editingSecret.value = null;
  } catch (cause) {
    modalError.value = getApiErrorMessage(cause, translate('Failed to save managed secret.'));
  } finally {
    savingModal.value = false;
  }
}

async function remove(secret: ManagedSecretAttachment) {
  if (!props.parentId) return;
  if (!window.confirm(translate('Delete secret “{name}”?', { name: secret.name }))) return;

  busy.value = true;
  actionError.value = null;
  try {
    const response = await deleteManagedSecret(props.parent, props.parentId, secret.id);
    replaceSecrets(response.secrets || []);
  } catch (cause) {
    actionError.value = getApiErrorMessage(cause, translate('Failed to delete managed secret.'));
  } finally {
    busy.value = false;
  }
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
