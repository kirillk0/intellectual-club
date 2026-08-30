<template>
  <ModalWindow
    :open="open"
    max-width="560px"
    :aria-label="title"
    :cancel-disabled="saving"
    :submit-disabled="saving || !valid"
    submit-shortcut="auto"
    @cancel="close"
    @submit="submit"
  >
    <h3 class="managed-secret-modal__title">{{ title }}</h3>

    <div class="stack">
      <label>
        {{ translate('Name') }}
        <input
          v-model="form.name"
          class="full"
          autocomplete="off"
          :disabled="saving"
          autofocus
        />
      </label>

      <label>
        {{ translate('Environment variable') }}
        <input
          v-model="form.env_name"
          class="full"
          autocomplete="off"
          spellcheck="false"
          :disabled="saving"
          placeholder="GITLAB_TOKEN"
        />
      </label>

      <label>
        {{ translate('Description visible to the model') }}
        <textarea
          v-model="form.description"
          class="full managed-secret-modal__description"
          rows="3"
          :disabled="saving"
        />
      </label>

      <label>
        {{ editing ? translate('New value') : translate('Value') }}
        <input
          v-model="form.value"
          class="full"
          type="password"
          autocomplete="new-password"
          spellcheck="false"
          :disabled="saving"
        />
        <div v-if="editing" class="muted managed-secret-modal__hint">
          {{ translate('Leave blank to keep the current value.') }}
        </div>
      </label>

      <p v-if="validationError" class="error-text managed-secret-modal__error">
        {{ validationError }}
      </p>
      <p v-if="error" class="error-text managed-secret-modal__error">{{ error }}</p>
    </div>

    <div class="modal-actions">
      <button class="primary" type="button" :disabled="saving || !valid" @click="submit">
        {{ saving ? translate('Saving…') : translate('Save') }}
      </button>
      <button type="button" :disabled="saving" @click="close">{{ translate('Cancel') }}</button>
    </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { computed, reactive, watch } from 'vue';

import ModalWindow from '@/components/ModalWindow.vue';
import type { ManagedSecretInput } from '@/api/managedSecrets';
import type { ManagedSecretDraftItem } from '@/features/catalogs/model/useManagedSecretsState';
import { translate } from '@/i18n';

const props = defineProps<{
  open: boolean;
  secret: ManagedSecretDraftItem | null;
  saving: boolean;
  error: string | null;
}>();

const emit = defineEmits<{
  (event: 'update:open', value: boolean): void;
  (event: 'save', value: ManagedSecretInput): void;
}>();

const form = reactive<ManagedSecretInput>({
  name: '',
  env_name: '',
  description: '',
  value: '',
});

const editing = computed(() => props.secret !== null);
const title = computed(() => translate(editing.value ? 'Edit secret' : 'Create secret'));
const envNameValid = computed(() => /^[A-Za-z_][A-Za-z0-9_]*$/u.test(form.env_name.trim()));
const valid = computed(
  () =>
    form.name.trim().length > 0 &&
    envNameValid.value &&
    (editing.value || Boolean(form.value))
);
const validationError = computed(() => {
  if (form.env_name.trim() && !envNameValid.value) {
    return translate('Environment variable name is invalid.');
  }
  return null;
});

watch(
  () => [props.open, props.secret] as const,
  ([open, secret]) => {
    if (!open) return;
    form.name = secret?.name || '';
    form.env_name = secret?.env_name || '';
    form.description = secret?.description || '';
    form.value = '';
  },
  { immediate: true }
);

function close() {
  if (!props.saving) emit('update:open', false);
}

function submit() {
  if (!valid.value || props.saving) return;
  emit('save', {
    name: form.name.trim(),
    env_name: form.env_name.trim(),
    description: form.description,
    ...(form.value ? { value: form.value } : {}),
  });
}
</script>

<style scoped>
.managed-secret-modal__title {
  margin: 0 0 14px;
}

.managed-secret-modal__description {
  height: 84px;
  min-height: 84px;
  resize: vertical;
}

.managed-secret-modal__hint {
  margin-top: 4px;
}

.managed-secret-modal__error {
  margin: 0;
}
</style>
