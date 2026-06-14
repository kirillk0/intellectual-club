<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Administration</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <button
            class="icon-button primary toolbar-create-button"
            type="button"
            @click="createUser"
            :disabled="loading"
            aria-label="New user"
            title="New user"
          >
            <SvgIcon name="plus" size="16" />
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <AdministrationNav />

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
              <span v-if="lastChangeLabel(user)"> · {{ lastChangeLabel(user) }}</span>
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
import { useSessionAuth } from '@/features/auth/session';
import { formatRelativeDateTime } from '@/utils/dates';
import type { AdminUser } from '@/types/api';

const route = useRoute();
const router = useRouter();

const { currentUser } = useSessionAuth();

const loading = ref(false);
const error = ref<string | null>(null);
const users = ref<AdminUser[]>([]);

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

function lastChangeLabel(user: AdminUser) {
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
  const navKey = createRecordset(ids, { returnTo: route.fullPath });
  router.push({ path: `/administration/users/${id}`, query: { navKey, returnTo: route.fullPath } });
}

function createUser() {
  const ids = visibleUsers.value.map((user) => user.id);
  const navKey = createRecordset(ids, { returnTo: route.fullPath });
  router.push({ path: '/administration/users/new', query: { navKey, returnTo: route.fullPath } });
}

async function loadUsers() {
  loading.value = true;
  error.value = null;

  try {
    const payload = await api.get<{ users: AdminUser[] }>('/api/bff/admin/users');
    users.value = Array.isArray(payload.users) ? payload.users : [];
  } catch (e) {
    console.error(e);
    error.value = e instanceof Error ? e.message : 'Failed to load users.';
  } finally {
    loading.value = false;
  }
}

onMounted(() => {
  loadUsers();
});
</script>
