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

    <PullToRefresh :refresh="loadGroups" :disabled="loading">
      <section class="card stack">
        <label>
          Search
          <input v-model="search" type="search" class="full" placeholder="Search groups" />
        </label>
      </section>

      <InitialRoutePlaceholder v-if="loading" />
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
    </PullToRefresh>
  </div>
</template>

<script setup lang="ts">
import { useQuery } from '@tanstack/vue-query';
import { computed, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import AdministrationNav from '@/components/AdministrationNav.vue';
import InitialRoutePlaceholder from '@/components/InitialRoutePlaceholder.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import PullToRefresh from '@/components/PullToRefresh.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { listAdminUserGroups } from '@/api/adminAshApi';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import { serverStateKeys } from '@/features/serverState/queryClient';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import { formatRelativeDateTime } from '@/utils/dates';
import type { AdminUserGroup } from '@/types/api';

const route = useRoute();
const router = useRouter();
const stackNav = useStackNavigation();

const groupsQuery = useQuery<AdminUserGroup[]>({
  queryKey: serverStateKeys.collection('user-groups', 'administration-index'),
  queryFn: ({ signal }) => listAdminUserGroups(signal),
});

const groups = computed(() => groupsQuery.data.value ?? []);
const loading = computed(() => groupsQuery.isPending.value);
const error = computed(() => {
  if (groupsQuery.data.value || !groupsQuery.error.value) return null;
  return groupsQuery.error.value instanceof Error
    ? groupsQuery.error.value.message
    : 'Failed to load groups.';
});

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
  await groupsQuery.refetch({ cancelRefetch: true });
}
</script>
