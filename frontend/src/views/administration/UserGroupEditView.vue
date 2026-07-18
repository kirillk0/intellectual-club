<template>
  <div class="stack">
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

    <RemoteUpdateNotice
      v-if="remoteUpdateAvailable"
      @reload="reloadRemoteDocument"
      @keep-editing="keepEditingRemoteDocument"
    />

    <fieldset class="stack" :disabled="loading || saving || Boolean(loadError)">
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
        <div class="muted">Created: {{ detailValue(form.created_at) }}</div>
        <div class="muted">Updated: {{ detailValue(form.updated_at) }}</div>
      </div>
    </fieldset>
  </div>

</template>

<script setup lang="ts">
import { useQuery } from '@tanstack/vue-query';
import { computed } from 'vue';
import CrudHeader from '@/components/CrudHeader.vue';
import RemoteUpdateNotice from '@/components/RemoteUpdateNotice.vue';
import { listAdminUsers } from '@/api/adminAshApi';
import { useCrudEditor } from '@/features/catalogs/model/useCrudEditor';
import { useUnsavedChangesGuard } from '@/features/catalogs/model/useUnsavedChangesGuard';
import { serverStateKeys } from '@/features/serverState/queryClient';
import { toIntId, type JsonApiResource } from '@/api/jsonApi';
import { formatRelativeDateTime } from '@/utils/dates';
import type { AdminUser } from '@/types/api';

type GroupForm = {
  name: string;
  user_ids: number[];
  created_at: string | null;
  updated_at: string | null;
};

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

const usersQuery = useQuery<AdminUser[]>({
  queryKey: serverStateKeys.reference('users', 'administration-group-editor'),
  queryFn: ({ signal }) => listAdminUsers(signal),
});

const availableUsers = computed(() => normalizeUsers(usersQuery.data.value || []));
const usersError = computed(() => {
  if (usersQuery.data.value || !usersQuery.error.value) return null;
  return usersQuery.error.value instanceof Error
    ? usersQuery.error.value.message
    : 'Failed to load users.';
});

const editor = useCrudEditor<GroupForm>({
  type: 'user-groups',
  basePath: '/api/ash/user-groups',
  indexPath: '/administration/user-groups',
  editPath: (id) => `/administration/user-groups/${id}`,
  defaultForm: () => ({
    name: '',
    user_ids: [],
    created_at: null,
    updated_at: null,
  }),
  fromApi: (resource) => ({
    name: String(resource.attributes?.name || ''),
    user_ids: relationshipIds(resource, 'users'),
    created_at: optionalStringAttribute(resource, 'created_at'),
    updated_at: optionalStringAttribute(resource, 'updated_at'),
  }),
  toAttributes: (form) => ({
    name: form.name,
    users: normalizeIdList(form.user_ids),
  }),
  normalizeForDirty: (form) => ({
    name: form.name,
    user_ids: normalizeIdList(form.user_ids),
  }),
  documentQuery: () => {
    const params = new URLSearchParams();
    params.set('include', 'users');
    return params;
  },
});

const form = editor.form;
const loaded = editor.loaded;
const loading = computed(() => editor.loading.value || usersQuery.isPending.value);
const saving = editor.saving;
const loadError = editor.loadError;
const remoteUpdateAvailable = editor.remoteUpdateAvailable;
const reloadRemoteDocument = editor.reloadRemoteDocument;
const keepEditingRemoteDocument = editor.keepEditingRemoteDocument;
const isNew = editor.isNew;
const totalCount = editor.totalCount;
const positionNumber = editor.positionNumber;
const navDisabled = editor.navDisabled;
const goPrev = editor.goPrev;
const goNext = editor.goNext;
const createNew = editor.createNew;
const goList = editor.goList;
const remove = editor.remove;
const saveErrors = editor.errors;
const saveFormErrors = computed(() => saveErrors.formErrors.value);
const dirty = editor.dirty;
const headerDirty = computed(() => dirty.value && !loading.value && !loadError.value);

useUnsavedChangesGuard(dirty);

function toggleUser(userId: number) {
  form.user_ids = normalizeIdList(
    form.user_ids.includes(userId)
      ? form.user_ids.filter((value) => value !== userId)
      : [...form.user_ids, userId]
  );
  saveErrors.clearField('users');
}

function reset() {
  editor.reset();
}

function detailValue(value?: string | null) {
  return formatRelativeDateTime(value) || '—';
}

async function save() {
  await editor.save();
}
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
