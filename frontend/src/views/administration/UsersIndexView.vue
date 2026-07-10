<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Administration</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <button
            class="icon-button icon-button--labeled primary toolbar-create-button"
            type="button"
            @click="createUser"
            :disabled="loading"
            aria-label="New user"
            title="New user"
          >
            <SvgIcon name="plus" size="16" />
            <span class="icon-button__label">New user</span>
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <AdministrationNav />

    <PullToRefresh :refresh="loadUsers" :disabled="loading">
      <section class="card stack">
        <label>
          Search
          <input v-model="search" type="search" class="full" placeholder="Search users" />
        </label>
      </section>

      <p v-if="loading" class="muted">Loading…</p>
      <p v-else-if="error" class="error-text">{{ error }}</p>

      <section v-else class="card stack">
        <div class="list catalog-list">
          <button
            v-for="user in visibleUsers"
            :key="user.id"
            type="button"
            class="row catalog-row"
            @click="openUser(user.id)"
          >
            <div class="catalog-row__main">
              <div class="catalog-row__title">
                {{ user.username }}
              </div>
              <div class="catalog-row__subtitle">
                {{ user.is_admin ? 'Administrator' : 'Standard user' }}
                <span v-if="activityOrChangeLabel(user)"> · {{ activityOrChangeLabel(user) }}</span>
              </div>
            </div>
            <div class="catalog-row__meta">
              <span v-if="user.is_admin" class="badge">Admin</span>
              <span v-if="user.id === currentUser?.id" class="badge">You</span>
              <span class="catalog-row__chevron" aria-hidden="true">›</span>
            </div>
          </button>
        </div>

        <p v-if="!visibleUsers.length" class="muted">No users found.</p>
      </section>
    </PullToRefresh>
  </div>
</template>

<script setup lang="ts">
import { useQuery } from '@tanstack/vue-query';
import { computed, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import AdministrationNav from '@/components/AdministrationNav.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import PullToRefresh from '@/components/PullToRefresh.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { listAdminUsers } from '@/api/adminAshApi';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import { useSessionAuth } from '@/features/auth/session';
import { serverStateKeys } from '@/features/serverState/queryClient';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import { formatRelativeDateTime } from '@/utils/dates';
import type { AdminUser } from '@/types/api';

const route = useRoute();
const router = useRouter();
const stackNav = useStackNavigation();

const { currentUser } = useSessionAuth();

const usersQuery = useQuery<AdminUser[]>({
  queryKey: serverStateKeys.collection('users', 'administration-index'),
  queryFn: ({ signal }) => listAdminUsers(signal),
});

const users = computed(() => usersQuery.data.value ?? []);
const loading = computed(() => usersQuery.isPending.value);
const error = computed(() => {
  if (usersQuery.data.value || !usersQuery.error.value) return null;
  return usersQuery.error.value instanceof Error
    ? usersQuery.error.value.message
    : 'Failed to load users.';
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

function activityOrChangeLabel(user: AdminUser) {
  const active = formatRelativeDateTime(user.last_activity_at);
  if (active) return `Active ${active}`;
  const updated = formatRelativeDateTime(user.updated_at);
  if (updated) return `Updated ${updated}`;
  const created = formatRelativeDateTime(user.created_at);
  return created ? `Created ${created}` : '';
}

const visibleUsers = computed(() => {
  const q = normalize(search.value);
  const rows = [...users.value].sort((a, b) => a.username.localeCompare(b.username) || a.id - b.id);
  if (!q) return rows;

  return rows.filter((user) =>
    normalize(`${user.username} ${user.is_admin ? 'administrator admin' : 'standard user'}`).includes(q)
  );
});

function openUser(id: number) {
  const ids = visibleUsers.value.map((user) => user.id);
  const recordsetKey = createRecordset(ids);
  stackNav.open({ path: `/administration/users/${id}`, query: { recordsetKey } });
}

function createUser() {
  const ids = visibleUsers.value.map((user) => user.id);
  const recordsetKey = createRecordset(ids);
  stackNav.open({ path: '/administration/users/new', query: { recordsetKey } });
}

async function loadUsers() {
  await usersQuery.refetch({ cancelRefetch: true });
}
</script>
