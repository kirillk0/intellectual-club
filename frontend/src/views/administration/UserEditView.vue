<template>
  <div v-if="loaded" class="stack">
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

    <fieldset class="stack" :disabled="loading || saving || Boolean(loadError)">
      <div v-if="loading" class="loading-float" aria-live="polite">Loading…</div>

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
        <div class="muted">Created: {{ detailValue(userMeta.created_at) }}</div>
        <div class="muted">Updated: {{ detailValue(userMeta.updated_at) }}</div>
        <div v-if="isSelf" class="muted">This is the account used for the current session.</div>
      </div>
    </fieldset>
  </div>

  <p v-else class="muted">Loading…</p>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import CrudHeader from '@/components/CrudHeader.vue';
import { api, isHttpError } from '@/api/client';
import { fetchCurrentUser, useSessionAuth } from '@/features/auth/session';
import {
  appendRecordsetId,
  getRecordset,
  removeRecordsetId,
} from '@/features/catalogs/model/recordsets';
import { useCrudRecordsetNavigation } from '@/features/catalogs/model/useCrudRecordsetNavigation';
import { useJsonDirtyCompare } from '@/features/catalogs/model/useJsonDirtyCompare';
import { useUnsavedChangesGuard } from '@/features/catalogs/model/useUnsavedChangesGuard';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import { toIntId } from '@/api/jsonApi';
import { formatRelativeDateTime } from '@/utils/dates';
import type { AdminUser, AdminUserGroup, AdminUserGroupSummary } from '@/types/api';

type UserForm = {
  username: string;
  is_admin: boolean;
  group_ids: number[];
};

type ErrorMap = Record<string, string[]>;

function pickQuery(query: Record<string, string | number | boolean | null | undefined>) {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(query)) {
    if (value === null || value === undefined) continue;
    out[key] = String(value);
  }
  return out;
}

function pickLocationQueryValue(raw: unknown): string | undefined {
  if (Array.isArray(raw)) {
    const first = raw.find((item) => item !== null && item !== undefined);
    return first === null || first === undefined ? undefined : String(first);
  }

  if (raw === null || raw === undefined) return undefined;
  return String(raw);
}

function cloneForm(form: UserForm): UserForm {
  return JSON.parse(JSON.stringify(form)) as UserForm;
}

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
const stack = useNavigationStack();
const stackNav = useStackNavigation();

const { currentUser } = useSessionAuth();

const idParam = computed(() => route.params.id as string | undefined);
const isNew = computed(() => !idParam.value || idParam.value === 'new');
const numericId = computed(() => {
  if (isNew.value) return undefined;
  const id = toIntId(idParam.value);
  return id ?? undefined;
});

const navKey = computed(() => route.query.navKey as string | undefined);
const recordsetReturnTo = computed(() => getRecordset(navKey.value)?.returnTo ?? null);
const explicitReturnTo = computed(() => (route.query.returnTo as string | undefined) ?? null);
const returnTo = computed(() => explicitReturnTo.value ?? recordsetReturnTo.value);

const form = reactive<UserForm>({
  username: '',
  is_admin: false,
  group_ids: [],
});

const base = ref<UserForm>(cloneForm(form));
const userMeta = reactive<Pick<AdminUser, 'created_at' | 'updated_at'>>({
  created_at: null,
  updated_at: null,
});

const passwordForm = reactive({
  password: '',
  password_confirmation: '',
});

const loaded = ref(false);
const loading = ref(false);
const saving = ref(false);
const resettingPassword = ref(false);
const deleting = ref(false);
const loadError = ref<string | null>(null);
const groupsError = ref<string | null>(null);
const availableGroups = ref<AdminUserGroupSummary[]>([]);

const saveErrors = createErrorState();
const resetErrors = createErrorState();
const saveFormErrors = computed(() => saveErrors.formErrors.value);
const resetFormErrors = computed(() => resetErrors.formErrors.value);
const activePasswordFormErrors = computed(() => (isNew.value ? saveFormErrors.value : resetFormErrors.value));

const baseDirty = useJsonDirtyCompare(() => form, () => base.value);
const dirty = computed(() => {
  if (!isNew.value) return baseDirty.value;
  return (
    baseDirty.value ||
    passwordForm.password.trim() !== '' ||
    passwordForm.password_confirmation.trim() !== ''
  );
});

const headerDirty = computed(() => dirty.value && !loading.value && !loadError.value);
const isSelf = computed(() => !isNew.value && numericId.value === currentUser.value?.id);
const passwordMismatch = computed(() => {
  if (passwordForm.password === '' && passwordForm.password_confirmation === '') return false;
  return passwordForm.password !== passwordForm.password_confirmation;
});

const activePasswordErrors = computed(() => (isNew.value ? saveErrors : resetErrors));
const canResetPassword = computed(() => {
  return (
    !isNew.value &&
    passwordForm.password.trim() !== '' &&
    passwordForm.password_confirmation.trim() !== '' &&
    !passwordMismatch.value
  );
});

useUnsavedChangesGuard(dirty);

const editorQuery = computed(() => {
  const query = pickQuery({
    navKey: navKey.value,
    returnTo: returnTo.value,
  });

  const q = pickLocationQueryValue(route.query.q);
  if (q !== undefined) query.q = q;

  return query;
});

const navigateTo = (id: number) => {
  const target = { path: `/administration/users/${id}`, query: editorQuery.value };
  if (stack.active.value) {
    return stackNav.replace(target);
  }
  return stackNav.push(target);
};

const { totalCount, positionNumber, navDisabled, goPrev, goNext } = useCrudRecordsetNavigation({
  recordsetKey: navKey,
  currentId: numericId,
  isNew,
  navigate: navigateTo,
});

function applyUser(user: AdminUser) {
  form.username = String(user.username || '');
  form.is_admin = Boolean(user.is_admin);
  form.group_ids = normalizeIdList((user.groups || []).map((group) => Number(group.id)));
  base.value = cloneForm(form);
  userMeta.created_at = user.created_at ?? null;
  userMeta.updated_at = user.updated_at ?? null;
}

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

function reset() {
  Object.assign(form, cloneForm(base.value));
  saveErrors.clear();

  if (isNew.value) {
    resetPasswordForm();
  }
}

function goList() {
  if (stack.active.value) {
    stackNav.close();
    return;
  }

  stackNav.push(returnTo.value || '/administration/users');
}

function createNew() {
  stackNav.push({ path: '/administration/users/new', query: editorQuery.value });
}

function detailValue(value?: string | null) {
  return formatRelativeDateTime(value) || '—';
}

function extractErrorMessage(error: unknown, fallback: string) {
  if (!isHttpError(error)) {
    return error instanceof Error ? error.message : fallback;
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

async function load() {
  loading.value = true;
  loadError.value = null;
  groupsError.value = null;
  saveErrors.clear();
  resetErrors.clear();

  try {
    try {
      const groupsPayload = await api.get<{ groups: AdminUserGroup[] }>('/api/bff/admin/user-groups');
      availableGroups.value = normalizeGroupOptions(Array.isArray(groupsPayload.groups) ? groupsPayload.groups : []);
    } catch (error) {
      console.error(error);
      availableGroups.value = [];
      groupsError.value = extractErrorMessage(error, 'Failed to load groups.');
    }

    if (isNew.value) {
      form.username = '';
      form.is_admin = false;
      form.group_ids = [];
      base.value = cloneForm(form);
      userMeta.created_at = null;
      userMeta.updated_at = null;
      resetPasswordForm();
      return;
    }

    if (numericId.value === undefined) {
      loadError.value = 'Invalid id.';
      return;
    }

    const payload = await api.get<{ user: AdminUser }>(`/api/bff/admin/users/${numericId.value}`);
    applyUser(payload.user);
    resetPasswordForm();
  } catch (error) {
    console.error(error);
    loadError.value = extractErrorMessage(error, 'Failed to load user.');
  } finally {
    loading.value = false;
    loaded.value = true;
  }
}

async function syncCurrentSessionIfNeeded(updatedUser: AdminUser) {
  if (updatedUser.id !== currentUser.value?.id) return;
  await fetchCurrentUser();
}

async function save() {
  if (saving.value) return;
  saveErrors.clear();

  if (isNew.value && passwordMismatch.value) {
    saveErrors.fieldErrors.value = {
      ...saveErrors.fieldErrors.value,
      password_confirmation: ['Passwords do not match.'],
    };
    return;
  }

  saving.value = true;

  try {
    if (isNew.value) {
      const payload = await api.post<{ user: AdminUser }>('/api/bff/admin/users', {
        username: form.username,
        is_admin: form.is_admin,
        group_ids: form.group_ids,
        password: passwordForm.password,
        password_confirmation: passwordForm.password_confirmation,
      });

      const createdUser = payload.user;
      applyUser(createdUser);
      resetPasswordForm();

      if (navKey.value) appendRecordsetId(navKey.value, createdUser.id);

      await stackNav.replace({
        path: `/administration/users/${createdUser.id}`,
        query: editorQuery.value,
      });
    } else {
      if (numericId.value === undefined) return;

      const payload = await api.patch<{ user: AdminUser }>(`/api/bff/admin/users/${numericId.value}`, {
        username: form.username,
        is_admin: form.is_admin,
        group_ids: form.group_ids,
      });

      applyUser(payload.user);
      await syncCurrentSessionIfNeeded(payload.user);
    }
  } catch (error) {
    if (!saveErrors.setFromHttpError(error)) {
      console.error(error);
      alert(extractErrorMessage(error, 'Failed to save user.'));
    }
  } finally {
    saving.value = false;
  }
}

async function remove() {
  if (deleting.value || isNew.value || numericId.value === undefined) return;
  if (!window.confirm(`Delete user "${form.username}"?`)) return;

  deleting.value = true;

  try {
    await api.del(`/api/bff/admin/users/${numericId.value}`);

    if (navKey.value) removeRecordsetId(navKey.value, numericId.value);

    if (stack.active.value) {
      stackNav.close();
    } else {
      await stackNav.replace(returnTo.value || '/administration/users');
    }
  } catch (error) {
    console.error(error);
    alert(extractErrorMessage(error, 'Failed to delete user.'));
  } finally {
    deleting.value = false;
  }
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
    const payload = await api.post<{ user: AdminUser }>(
      `/api/bff/admin/users/${numericId.value}/reset-password`,
      {
        password: passwordForm.password,
        password_confirmation: passwordForm.password_confirmation,
      }
    );

    userMeta.updated_at = payload.user.updated_at ?? userMeta.updated_at;
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

onMounted(() => {
  load();
});

watch(
  () => idParam.value,
  () => {
    void load();
  }
);
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
