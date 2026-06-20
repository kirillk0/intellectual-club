<template>
  <div v-if="loaded" class="stack">
    <CrudHeader
      title="User group"
      :dirty="headerDirty"
      :position="positionNumber"
      :total="totalCount"
      :navDisabled="navDisabled"
      :showDelete="!isNew"
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

        <label :class="{ 'field-error': saveErrors.hasField('name') }">
          Name
          <input v-model="form.name" class="full" autocomplete="off" @input="saveErrors.clearField('name')" />
          <div v-if="saveErrors.hasField('name')" class="error-text">
            {{ saveErrors.messageFor('name') }}
          </div>
        </label>
      </div>

      <div class="card stack">
        <div class="flex admin-membership-header">
          <h3 style="margin: 0">Users</h3>
          <div class="muted">{{ form.user_ids.length }} selected</div>
        </div>

        <p v-if="usersError" class="error-text">{{ usersError }}</p>
        <p v-else-if="!availableUsers.length" class="muted">No users available.</p>

        <label
          v-for="user in availableUsers"
          :key="user.id"
          class="admin-membership-option"
        >
          <input
            type="checkbox"
            :checked="form.user_ids.includes(user.id)"
            @change="toggleUser(user.id)"
          />
          <span>{{ user.username }}</span>
          <span v-if="user.is_admin" class="badge">Admin</span>
        </label>
      </div>

      <div v-if="!isNew" class="card stack">
        <h3 style="margin: 0">Details</h3>
        <div class="muted">Created: {{ detailValue(groupMeta.created_at) }}</div>
        <div class="muted">Updated: {{ detailValue(groupMeta.updated_at) }}</div>
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
import {
  appendRecordsetId,
  removeRecordsetId,
} from '@/features/catalogs/model/recordsets';
import { publishEntityChange } from '@/features/entities/entityChanges';
import { useCrudRecordsetNavigation } from '@/features/catalogs/model/useCrudRecordsetNavigation';
import { useJsonDirtyCompare } from '@/features/catalogs/model/useJsonDirtyCompare';
import { useUnsavedChangesGuard } from '@/features/catalogs/model/useUnsavedChangesGuard';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import { toIntId } from '@/api/jsonApi';
import { formatRelativeDateTime } from '@/utils/dates';
import type { AdminUser, AdminUserGroup } from '@/types/api';

type GroupForm = {
  name: string;
  user_ids: number[];
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

function cloneForm(form: GroupForm): GroupForm {
  return JSON.parse(JSON.stringify(form)) as GroupForm;
}

function normalizeIdList(ids: number[]) {
  return Array.from(
    new Set(
      ids.filter((value) => Number.isInteger(value) && value > 0)
    )
  ).sort((a, b) => a - b);
}

function normalizeUsers(users: AdminUser[]) {
  return [...users]
    .map((user) => ({
      id: Number(user.id),
      username: String(user.username || ''),
      is_admin: Boolean(user.is_admin),
    }))
    .filter((user) => Number.isInteger(user.id) && user.id > 0 && user.username !== '')
    .sort((a, b) => a.username.localeCompare(b.username) || a.id - b.id);
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

const route = useRoute();
const stack = useNavigationStack();
const stackNav = useStackNavigation();

const idParam = computed(() => route.params.id as string | undefined);
const isNew = computed(() => !idParam.value || idParam.value === 'new');
const numericId = computed(() => {
  if (isNew.value) return undefined;
  const id = toIntId(idParam.value);
  return id ?? undefined;
});

const recordsetKey = computed(
  () => pickLocationQueryValue(route.query.recordsetKey) ?? pickLocationQueryValue(route.query.navKey)
);
const explicitReturnTo = computed(() => pickLocationQueryValue(route.query.returnTo) ?? null);
const returnTo = computed(() => explicitReturnTo.value);

const form = reactive<GroupForm>({
  name: '',
  user_ids: [],
});

const base = ref<GroupForm>(cloneForm(form));
const groupMeta = reactive<Pick<AdminUserGroup, 'created_at' | 'updated_at'>>({
  created_at: null,
  updated_at: null,
});

const loaded = ref(false);
const loading = ref(false);
const saving = ref(false);
const deleting = ref(false);
const loadError = ref<string | null>(null);
const usersError = ref<string | null>(null);
const availableUsers = ref<AdminUser[]>([]);

const saveErrors = createErrorState();
const saveFormErrors = computed(() => saveErrors.formErrors.value);

const dirty = useJsonDirtyCompare(() => form, () => base.value);
const headerDirty = computed(() => dirty.value && !loading.value && !loadError.value);

useUnsavedChangesGuard(dirty);

const editorQuery = computed(() => {
  const query = pickQuery({
    recordsetKey: recordsetKey.value,
  });

  return query;
});

const navigateTo = (id: number) => {
  const target = { path: `/administration/user-groups/${id}`, query: editorQuery.value };
  if (stack.active.value) {
    return stackNav.replace(target);
  }
  return stackNav.push(target);
};

const { totalCount, positionNumber, navDisabled, goPrev, goNext } = useCrudRecordsetNavigation({
  recordsetKey,
  currentId: numericId,
  isNew,
  navigate: navigateTo,
});

function applyGroup(group: AdminUserGroup) {
  form.name = String(group.name || '');
  form.user_ids = normalizeIdList((group.users || []).map((user) => Number(user.id)));
  base.value = cloneForm(form);
  groupMeta.created_at = group.created_at ?? null;
  groupMeta.updated_at = group.updated_at ?? null;
}

function toggleUser(userId: number) {
  form.user_ids = normalizeIdList(
    form.user_ids.includes(userId)
      ? form.user_ids.filter((value) => value !== userId)
      : [...form.user_ids, userId]
  );
  saveErrors.clearField('users');
}

function reset() {
  Object.assign(form, cloneForm(base.value));
  saveErrors.clear();
}

function goList() {
  if (stack.active.value) {
    stackNav.close();
    return;
  }

  stackNav.push(returnTo.value || '/administration/user-groups');
}

function createNew() {
  stackNav.push({ path: '/administration/user-groups/new', query: editorQuery.value });
}

function detailValue(value?: string | null) {
  return formatRelativeDateTime(value) || '—';
}

async function loadUsers() {
  try {
    const payload = await api.get<{ users: AdminUser[] }>('/api/bff/admin/users');
    availableUsers.value = normalizeUsers(Array.isArray(payload.users) ? payload.users : []);
    usersError.value = null;
  } catch (error) {
    console.error(error);
    availableUsers.value = [];
    usersError.value = extractErrorMessage(error, 'Failed to load users.');
  }
}

async function load() {
  loading.value = true;
  loadError.value = null;
  saveErrors.clear();

  try {
    await loadUsers();

    if (isNew.value) {
      form.name = '';
      form.user_ids = [];
      base.value = cloneForm(form);
      groupMeta.created_at = null;
      groupMeta.updated_at = null;
      return;
    }

    if (numericId.value === undefined) {
      loadError.value = 'Invalid id.';
      return;
    }

    const payload = await api.get<{ group: AdminUserGroup }>(`/api/bff/admin/user-groups/${numericId.value}`);
    applyGroup(payload.group);
  } catch (error) {
    console.error(error);
    loadError.value = extractErrorMessage(error, 'Failed to load group.');
  } finally {
    loading.value = false;
    loaded.value = true;
  }
}

async function save() {
  if (saving.value) return;
  saveErrors.clear();
  saving.value = true;

  try {
    if (isNew.value) {
      const payload = await api.post<{ group: AdminUserGroup }>('/api/bff/admin/user-groups', {
        name: form.name,
        user_ids: form.user_ids,
      });

      const createdGroup = payload.group;
      applyGroup(createdGroup);
      publishEntityChange({ kind: 'admin-user-group', operation: 'upsert', id: createdGroup.id, row: createdGroup });

      if (recordsetKey.value) appendRecordsetId(recordsetKey.value, createdGroup.id);

      await stackNav.replace({
        path: `/administration/user-groups/${createdGroup.id}`,
        query: editorQuery.value,
      });
    } else {
      if (numericId.value === undefined) return;

      const payload = await api.patch<{ group: AdminUserGroup }>(`/api/bff/admin/user-groups/${numericId.value}`, {
        name: form.name,
        user_ids: form.user_ids,
      });

      applyGroup(payload.group);
      publishEntityChange({ kind: 'admin-user-group', operation: 'upsert', id: payload.group.id, row: payload.group });
    }
  } catch (error) {
    if (!saveErrors.setFromHttpError(error)) {
      console.error(error);
      alert(extractErrorMessage(error, 'Failed to save group.'));
    }
  } finally {
    saving.value = false;
  }
}

async function remove() {
  if (deleting.value || isNew.value || numericId.value === undefined) return;
  if (!window.confirm(`Delete group "${form.name}"?`)) return;

  deleting.value = true;

  try {
    await api.del(`/api/bff/admin/user-groups/${numericId.value}`);
    publishEntityChange({ kind: 'admin-user-group', operation: 'delete', id: numericId.value });

    if (recordsetKey.value) removeRecordsetId(recordsetKey.value, numericId.value);

    if (stack.active.value) {
      stackNav.close();
    } else {
      await stackNav.replace(returnTo.value || '/administration/user-groups');
    }
  } catch (error) {
    console.error(error);
    alert(extractErrorMessage(error, 'Failed to delete group.'));
  } finally {
    deleting.value = false;
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
  .admin-membership-header {
    flex-direction: column;
    align-items: stretch;
  }
}
</style>
