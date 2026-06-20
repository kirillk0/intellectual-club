<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Administration</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <button
            class="icon-button icon-button--labeled primary toolbar-create-button"
            type="button"
            @click="createGroup"
            :disabled="loading"
            aria-label="New group"
            title="New group"
          >
            <SvgIcon name="plus" size="16" />
            <span class="icon-button__label">New group</span>
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <AdministrationNav />

    <section class="card stack">
      <label>
        Search
        <input v-model="search" type="search" class="full" placeholder="Search groups" />
      </label>
    </section>

    <p v-if="loading" class="muted">Loading…</p>
    <p v-else-if="error" class="error-text">{{ error }}</p>

    <section v-else class="card stack">
      <div class="list catalog-list">
        <button
          v-for="group in visibleGroups"
          :key="group.id"
          type="button"
          class="row catalog-row"
          @click="openGroup(group.id)"
        >
          <div class="catalog-row__main">
            <div class="catalog-row__title">
              {{ group.name }}
            </div>
            <div class="catalog-row__subtitle">
              {{ memberCountLabel(group) }}
              <span v-if="lastChangeLabel(group)"> · {{ lastChangeLabel(group) }}</span>
            </div>
          </div>
          <div class="catalog-row__meta">
            <span class="catalog-row__chevron" aria-hidden="true">›</span>
          </div>
        </button>
      </div>

      <p v-if="!visibleGroups.length" class="muted">No groups found.</p>
    </section>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import AdministrationNav from '@/components/AdministrationNav.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { api } from '@/api/client';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import { useLiveEntityRows } from '@/features/entities/entityChanges';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import { formatRelativeDateTime } from '@/utils/dates';
import type { AdminUserGroup } from '@/types/api';

const route = useRoute();
const router = useRouter();
const stackNav = useStackNavigation();

const loading = ref(false);
const error = ref<string | null>(null);
const groups = ref<AdminUserGroup[]>([]);

const search = ref(String(route.query.q || ''));

watch(
  () => route.query.q,
  (q) => {
    const next = String(q || '');
    if (next !== search.value) search.value = next;
  }
);

watch(
  () => search.value,
  (q) => {
    const next = q.trim() ? { ...route.query, q: q.trim() } : { ...route.query };
    if (!q.trim()) delete (next as any).q;
    router.replace({ query: next }).catch(() => {});
  }
);

function normalize(text: string) {
  return text.trim().toLowerCase();
}

function normalizeGroups(items: AdminUserGroup[]) {
  return [...items].sort((a, b) => a.name.localeCompare(b.name) || a.id - b.id);
}

function memberCountLabel(group: AdminUserGroup) {
  const count = Array.isArray(group.users) ? group.users.length : 0;
  return count === 1 ? '1 member' : `${count} members`;
}

function lastChangeLabel(group: AdminUserGroup) {
  const updated = formatRelativeDateTime(group.updated_at);
  if (updated) return `Updated ${updated}`;
  const created = formatRelativeDateTime(group.created_at);
  return created ? `Created ${created}` : '';
}

const visibleGroups = computed(() => {
  const q = normalize(search.value);
  const rows = normalizeGroups(groups.value);
  if (!q) return rows;

  return rows.filter((group) =>
    normalize(`${group.name} ${memberCountLabel(group)}`).includes(q)
  );
});

function normalizeGroupRow(value: unknown): AdminUserGroup | null {
  if (!value || typeof value !== 'object') return null;
  const group = value as AdminUserGroup;
  if (!Number.isInteger(group.id) || group.id <= 0) return null;
  return group;
}

async function fetchGroupRow(groupId: number): Promise<AdminUserGroup | null> {
  try {
    const payload = await api.get<{ group: AdminUserGroup }>(`/api/bff/admin/user-groups/${groupId}`);
    return normalizeGroupRow(payload.group);
  } catch (error) {
    console.warn('Failed to refresh user group row.', error);
    return null;
  }
}

function openGroup(id: number) {
  const ids = visibleGroups.value.map((group) => group.id);
  const recordsetKey = createRecordset(ids);
  stackNav.open({ path: `/administration/user-groups/${id}`, query: { recordsetKey } });
}

function createGroup() {
  const ids = visibleGroups.value.map((group) => group.id);
  const recordsetKey = createRecordset(ids);
  stackNav.open({ path: '/administration/user-groups/new', query: { recordsetKey } });
}

async function loadGroups() {
  loading.value = true;
  error.value = null;

  try {
    const payload = await api.get<{ groups: AdminUserGroup[] }>('/api/bff/admin/user-groups');
    groups.value = Array.isArray(payload.groups) ? payload.groups : [];
  } catch (e) {
    console.error(e);
    error.value = e instanceof Error ? e.message : 'Failed to load groups.';
  } finally {
    loading.value = false;
  }
}

useLiveEntityRows(groups, {
  kind: 'admin-user-group',
  getId: (row) => row.id,
  resolveRow: (change) => normalizeGroupRow(change.row) ?? fetchGroupRow(change.id),
  compare: (a, b) => a.name.localeCompare(b.name) || a.id - b.id,
});

onMounted(() => {
  loadGroups();
});
</script>
