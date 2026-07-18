<template>
  <div class="stack">
    <CrudHeader
      title="User"
      :dirty="headerDirty"
      :position="positionNumber"
      :total="totalCount"
      :navDisabled="navDisabled"
      :showDelete="!isNew && !isSelf"
      :saving="saving"
      @save="save"
      @cancel="reset"
      @close="goList"
      @create="createNew"
      @prev="goPrev"
      @next="goNext"
      @delete="remove"
    />

    <p v-if="loadError" class="error-text">{{ loadError }}</p>

    <RemoteUpdateNotice
      v-if="remoteUpdateAvailable"
      @reload="reloadRemoteDocument"
      @keep-editing="keepEditingRemoteDocument"
    />

    <fieldset class="stack" :disabled="loading || saving || Boolean(loadError)">
      <div class="card stack">
        <div v-if="saveFormErrors.length" class="error-text">{{ saveFormErrors.join(' ') }}</div>

        <label :class="{ 'field-error': saveErrors.hasField('username') }">
          Username
          <input v-model="form.username" class="full" autocomplete="username" @input="saveErrors.clearField('username')" />
          <div v-if="saveErrors.hasField('username')" class="error-text">
            {{ saveErrors.messageFor('username') }}
          </div>
        </label>

        <div class="stack" style="gap: 6px">
          <label style="display: flex; align-items: center; gap: 10px">
            <input
              v-model="form.is_admin"
              type="checkbox"
              :disabled="isSelf"
              @change="saveErrors.clearField('is_admin')"
            />
            Administrator
          </label>

          <div v-if="saveErrors.hasField('is_admin')" class="error-text">
            {{ saveErrors.messageFor('is_admin') }}
          </div>

          <div v-if="isSelf" class="muted">Admin access cannot be removed from your own account.</div>
        </div>
      </div>

      <div class="card stack">
        <div class="flex admin-membership-header">
          <h3 style="margin: 0">Groups</h3>
          <div class="muted">{{ form.group_ids.length }} selected</div>
        </div>

        <p v-if="groupsError" class="error-text">{{ groupsError }}</p>
        <p v-else-if="!availableGroups.length" class="muted">No groups created yet.</p>

        <label
          v-for="group in availableGroups"
          :key="group.id"
          class="admin-membership-option"
        >
          <input
            type="checkbox"
            :checked="form.group_ids.includes(group.id)"
            @change="toggleGroup(group.id)"
          />
          <span>{{ group.name }}</span>
        </label>
      </div>

      <div class="card stack">
        <h3 style="margin: 0">{{ isNew ? 'Initial password' : 'Reset password' }}</h3>
        <div
          v-if="activePasswordFormErrors.length"
          class="error-text"
        >
          {{ activePasswordFormErrors.join(' ') }}
        </div>

        <label :class="{ 'field-error': activePasswordErrors.hasField('password') }">
          Password
          <input
            v-model="passwordForm.password"
            class="full"
            type="password"
            autocomplete="new-password"
            spellcheck="false"
            @input="activePasswordErrors.clearField('password')"
          />
          <div v-if="activePasswordErrors.hasField('password')" class="error-text">
            {{ activePasswordErrors.messageFor('password') }}
          </div>
        </label>

        <label
          :class="{
            'field-error': passwordMismatch || activePasswordErrors.hasField('password_confirmation'),
          }"
        >
          Confirm password
          <input
            v-model="passwordForm.password_confirmation"
            class="full"
            type="password"
            autocomplete="new-password"
            spellcheck="false"
            @input="activePasswordErrors.clearField('password_confirmation')"
          />
          <div v-if="passwordMismatch" class="error-text">Passwords do not match.</div>
          <div v-else-if="activePasswordErrors.hasField('password_confirmation')" class="error-text">
            {{ activePasswordErrors.messageFor('password_confirmation') }}
          </div>
        </label>

        <div class="flex admin-password-actions">
          <div v-if="!isNew" class="muted">Administrators can reset a password without the current password.</div>
          <button
            v-if="!isNew"
            class="primary"
            type="button"
            :disabled="!canResetPassword || resettingPassword || saving"
            @click="resetPassword"
          >
            {{ resettingPassword ? 'Resetting…' : 'Reset password' }}
          </button>
        </div>
      </div>

      <div v-if="!isNew" class="card stack">
        <h3 style="margin: 0">Details</h3>
        <div class="muted">Last activity: {{ detailValue(form.last_activity_at) }}</div>
        <div class="muted">Created: {{ detailValue(form.created_at) }}</div>
        <div class="muted">Updated: {{ detailValue(form.updated_at) }}</div>
        <div v-if="isSelf" class="muted">This is the account used for the current session.</div>
      </div>
    </fieldset>
  </div>

</template>

<script setup lang="ts">
import { useQuery } from '@tanstack/vue-query';
import { computed, reactive, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import CrudHeader from '@/components/CrudHeader.vue';
import RemoteUpdateNotice from '@/components/RemoteUpdateNotice.vue';
import { isHttpError } from '@/api/client';
import {
  listAdminUserGroups,
  resetAdminUserPassword,
} from '@/api/adminAshApi';
import { fetchCurrentUser, useSessionAuth } from '@/features/auth/session';
import { useCrudEditor } from '@/features/catalogs/model/useCrudEditor';
import { useUnsavedChangesGuard } from '@/features/catalogs/model/useUnsavedChangesGuard';
import { serverStateKeys } from '@/features/serverState/queryClient';
import {
  fieldErrorsFromJsonApiErrors,
  formErrorsFromJsonApiErrors,
  getJsonApiErrors,
  toIntId,
  type JsonApiResource,
} from '@/api/jsonApi';
import { formatRelativeDateTime } from '@/utils/dates';
import type { AdminUserGroup, AdminUserGroupSummary } from '@/types/api';

type UserForm = {
  username: string;
  is_admin: boolean;
  group_ids: number[];
  created_at: string | null;
  updated_at: string | null;
  last_activity_at: string | null;
};

type ErrorMap = Record<string, string[]>;

function normalizeIdList(ids: number[]) {
  return Array.from(
    new Set(
      ids.filter((value) => Number.isInteger(value) && value > 0)
    )
  ).sort((a, b) => a - b);
}

function normalizeGroupOptions(groups: AdminUserGroup[] | AdminUserGroupSummary[]) {
  return [...groups]
    .map((group) => ({
      id: Number(group.id),
      name: String(group.name || ''),
    }))
    .filter((group) => Number.isInteger(group.id) && group.id > 0 && group.name !== '')
    .sort((a, b) => a.name.localeCompare(b.name) || a.id - b.id);
}

function createErrorState() {
  const formErrors = ref<string[]>([]);
  const fieldErrors = ref<ErrorMap>({});

  const clear = () => {
    formErrors.value = [];
    fieldErrors.value = {};
  };

  const clearField = (field: string) => {
    if (!fieldErrors.value[field]) return;
    const next = { ...fieldErrors.value };
    delete next[field];
    fieldErrors.value = next;
  };

  const hasField = (field: string) => Boolean(fieldErrors.value[field]?.length);
  const messageFor = (field: string) => (fieldErrors.value[field] || []).join(' ');

  const setFromHttpError = (error: unknown) => {
    if (!isHttpError(error)) return false;

    const jsonApiErrors = getJsonApiErrors(error);
    if (jsonApiErrors?.length) {
      formErrors.value = formErrorsFromJsonApiErrors(jsonApiErrors);
      fieldErrors.value = fieldErrorsFromJsonApiErrors(jsonApiErrors);
      return true;
    }

    const body = error.bodyJson;
    const nextFieldErrors: ErrorMap = {};
    const nextFormErrors: string[] = [];

    if (body && typeof body === 'object') {
      const payload = body as { error?: unknown; detail?: unknown; errors?: unknown };

      if (payload.errors && typeof payload.errors === 'object') {
        for (const [key, value] of Object.entries(payload.errors as Record<string, unknown>)) {
          const messages = Array.isArray(value)
            ? value.map((item) => String(item || '').trim()).filter((item) => item !== '')
            : [];

          if (!messages.length) continue;

          if (key === '_form') {
            nextFormErrors.push(...messages);
          } else {
            nextFieldErrors[key] = messages;
          }
        }
      }

      if (!nextFormErrors.length && typeof payload.error === 'string' && payload.error.trim() !== '') {
        nextFormErrors.push(payload.error.trim());
      }
    }

    formErrors.value = nextFormErrors;
    fieldErrors.value = nextFieldErrors;
    return true;
  };

  return {
    formErrors,
    fieldErrors,
    clear,
    clearField,
    hasField,
    messageFor,
    setFromHttpError,
  };
}

const route = useRoute();
const routeIsNew = computed(() => !route.params.id || route.params.id === 'new');
const { currentUser } = useSessionAuth();

const passwordForm = reactive({
  password: '',
  password_confirmation: '',
});

function relationshipIds(resource: JsonApiResource, name: string) {
  const data = resource.relationships?.[name]?.data;
  if (!Array.isArray(data)) return [];
  return normalizeIdList(
    data
      .map((item) => toIntId(item.id))
      .filter((id): id is number => typeof id === 'number')
  );
}

function optionalStringAttribute(resource: JsonApiResource, name: string) {
  const value = resource.attributes?.[name];
  return typeof value === 'string' && value !== '' ? value : null;
}

const groupsQuery = useQuery<AdminUserGroup[]>({
  queryKey: serverStateKeys.reference('user-groups', 'administration-user-editor'),
  queryFn: ({ signal }) => listAdminUserGroups(signal),
});

const availableGroups = computed<AdminUserGroupSummary[]>(() =>
  normalizeGroupOptions(groupsQuery.data.value || [])
);
const groupsError = computed(() => {
  if (groupsQuery.data.value || !groupsQuery.error.value) return null;
  return groupsQuery.error.value instanceof Error
    ? groupsQuery.error.value.message
    : 'Failed to load groups.';
});

const editor = useCrudEditor<UserForm>({
  type: 'users',
  basePath: '/api/ash/users',
  indexPath: '/administration/users',
  editPath: (id) => `/administration/users/${id}`,
  defaultForm: () => ({
    username: '',
    is_admin: false,
    group_ids: [],
    created_at: null,
    updated_at: null,
    last_activity_at: null,
  }),
  fromApi: (resource) => ({
    username: String(resource.attributes?.username || ''),
    is_admin: resource.attributes?.is_admin === true,
    group_ids: relationshipIds(resource, 'groups'),
    created_at: optionalStringAttribute(resource, 'created_at'),
    updated_at: optionalStringAttribute(resource, 'updated_at'),
    last_activity_at: optionalStringAttribute(resource, 'last_activity_at'),
  }),
  toAttributes: (form) => ({
    username: form.username,
    is_admin: form.is_admin,
    groups: normalizeIdList(form.group_ids),
    ...(routeIsNew.value
      ? {
          password: passwordForm.password,
          password_confirmation: passwordForm.password_confirmation,
        }
      : {}),
  }),
  normalizeForDirty: (form) => ({
    username: form.username,
    is_admin: form.is_admin,
    group_ids: normalizeIdList(form.group_ids),
  }),
  documentQuery: () => {
    const params = new URLSearchParams();
    params.set('include', 'groups');
    return params;
  },
});

const form = editor.form;
const loaded = editor.loaded;
const loading = computed(() => editor.loading.value || groupsQuery.isPending.value);
const saving = editor.saving;
const loadError = editor.loadError;
const remoteUpdateAvailable = editor.remoteUpdateAvailable;
const reloadRemoteDocument = editor.reloadRemoteDocument;
const keepEditingRemoteDocument = editor.keepEditingRemoteDocument;
const isNew = editor.isNew;
const numericId = editor.numericId;
const totalCount = editor.totalCount;
const positionNumber = editor.positionNumber;
const navDisabled = editor.navDisabled;
const goPrev = editor.goPrev;
const goNext = editor.goNext;
const createNew = editor.createNew;
const goList = editor.goList;
const remove = editor.remove;

const saveErrors = editor.errors;
const resetErrors = createErrorState();
const saveFormErrors = computed(() => saveErrors.formErrors.value);
const resetFormErrors = computed(() => resetErrors.formErrors.value);
const passwordDraftDirty = computed(
  () =>
    isNew.value &&
    (passwordForm.password.trim() !== '' || passwordForm.password_confirmation.trim() !== '')
);
editor.registerDirtySource(() => passwordDraftDirty.value);
const dirty = computed(() => editor.dirty.value || passwordDraftDirty.value);
const headerDirty = computed(() => dirty.value && !loading.value && !loadError.value);
const isSelf = computed(() => !isNew.value && numericId.value === currentUser.value?.id);
const passwordMismatch = computed(() => {
  if (passwordForm.password === '' && passwordForm.password_confirmation === '') return false;
  return passwordForm.password !== passwordForm.password_confirmation;
});
const activePasswordErrors = computed(() => (isNew.value ? saveErrors : resetErrors));
const activePasswordFormErrors = computed(() =>
  isNew.value ? saveFormErrors.value : resetFormErrors.value
);
const canResetPassword = computed(
  () =>
    !isNew.value &&
    passwordForm.password.trim() !== '' &&
    passwordForm.password_confirmation.trim() !== '' &&
    !passwordMismatch.value
);
const resettingPassword = ref(false);

useUnsavedChangesGuard(dirty);

function toggleGroup(groupId: number) {
  form.group_ids = normalizeIdList(
    form.group_ids.includes(groupId)
      ? form.group_ids.filter((value) => value !== groupId)
      : [...form.group_ids, groupId]
  );
  saveErrors.clearField('groups');
}

function resetPasswordForm() {
  passwordForm.password = '';
  passwordForm.password_confirmation = '';
}

watch(
  () => editor.idParam.value,
  () => {
    resetPasswordForm();
    resetErrors.clear();
  },
  { immediate: true }
);

function reset() {
  editor.reset();

  if (isNew.value) {
    resetPasswordForm();
  }
}

function detailValue(value?: string | null) {
  return formatRelativeDateTime(value) || '—';
}

function extractErrorMessage(error: unknown, fallback: string) {
  if (!isHttpError(error)) {
    return error instanceof Error ? error.message : fallback;
  }

  const jsonApiErrors = getJsonApiErrors(error);
  if (jsonApiErrors?.length) {
    const message = jsonApiErrors
      .map((item) => String(item.detail || item.title || '').trim())
      .filter((item) => item !== '')
      .join(' ');
    if (message) return message;
  }

  const body = error.bodyJson;
  if (body && typeof body === 'object') {
    const payload = body as { error?: unknown; detail?: unknown; errors?: unknown };

    if (payload.errors && typeof payload.errors === 'object') {
      const messages = Object.values(payload.errors as Record<string, unknown>)
        .flatMap((value) =>
          Array.isArray(value)
            ? value.map((item) => String(item || '').trim()).filter((item) => item !== '')
            : []
        )
        .filter((message) => message !== '');

      if (messages.length) return messages.join(' ');
    }

    if (typeof payload.error === 'string' && payload.error.trim() !== '') return payload.error.trim();
    if (typeof payload.detail === 'string' && payload.detail.trim() !== '') return payload.detail.trim();
  }

  return fallback;
}

async function syncCurrentSessionIfNeeded(userId: number | undefined) {
  if (userId !== currentUser.value?.id) return;
  await fetchCurrentUser();
}

async function save() {
  if (saving.value) return;
  saveErrors.clear();

  if (isNew.value && passwordMismatch.value) {
    saveErrors.setField('password_confirmation', 'Passwords do not match.');
    return;
  }

  const currentId = numericId.value;
  const saved = await editor.save();
  if (!saved) return;

  resetPasswordForm();
  await syncCurrentSessionIfNeeded(currentId);
}

async function resetPassword() {
  if (resettingPassword.value || isNew.value || numericId.value === undefined) return;
  resetErrors.clear();

  if (passwordMismatch.value) {
    resetErrors.fieldErrors.value = {
      ...resetErrors.fieldErrors.value,
      password_confirmation: ['Passwords do not match.'],
    };
    return;
  }

  resettingPassword.value = true;

  try {
    const updatedUser = await resetAdminUserPassword(numericId.value, {
      password: passwordForm.password,
      password_confirmation: passwordForm.password_confirmation,
    });

    if (numericId.value !== updatedUser.id) return;
    form.updated_at = updatedUser.updated_at ?? form.updated_at;
    resetPasswordForm();
  } catch (error) {
    if (!resetErrors.setFromHttpError(error)) {
      console.error(error);
      alert(extractErrorMessage(error, 'Failed to reset password.'));
    }
  } finally {
    resettingPassword.value = false;
  }
}
</script>

<style scoped>
.admin-password-actions {
  justify-content: space-between;
  align-items: center;
  gap: 12px;
}

.admin-membership-header {
  justify-content: space-between;
  align-items: center;
  gap: 12px;
}

.admin-membership-option {
  display: flex;
  align-items: center;
  gap: 10px;
}

@media (max-width: 720px) {
  .admin-password-actions {
    flex-direction: column;
    align-items: stretch;
  }

  .admin-membership-header {
    flex-direction: column;
    align-items: stretch;
  }
}
</style>
