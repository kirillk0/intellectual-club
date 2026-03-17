<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Knowledge Tags</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <button class="primary" type="button" @click="createTag" :disabled="loading">
            New tag
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <section class="card stack">
      <label>
        Search
        <input v-model="search" type="search" class="full" placeholder="Search tags" />
      </label>
    </section>

    <p v-if="loading" class="muted">Loading…</p>
    <p v-else-if="error" class="error-text">{{ error }}</p>

    <section v-else class="card stack">
      <div class="list">
        <button
          v-for="t in visibleTags"
          :key="t.id"
          type="button"
          class="row"
          style="text-align: left"
          @click="openTag(t.id)"
        >
          <div style="min-width: 0">
            <div style="font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">
              {{ t.full_name || t.name }}
            </div>
          </div>
          <span aria-hidden="true">›</span>
        </button>
      </div>

      <p v-if="!visibleTags.length" class="muted">No tags found.</p>
    </section>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { jsonApiList, toIntId, type JsonApiResource } from '@/api/jsonApi';
import { createRecordset } from '@/features/catalogs/model/recordsets';

type KnowledgeTagRow = {
  id: number;
  name: string;
  full_name: string;
};

const route = useRoute();
const router = useRouter();

const loading = ref(false);
const error = ref<string | null>(null);
const tags = ref<KnowledgeTagRow[]>([]);

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

function parseRow(resource: JsonApiResource): KnowledgeTagRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return {
    id,
    name: String(attrs.name || '').trim(),
    full_name: String(attrs.full_name || '').trim(),
  };
}

const visibleTags = computed(() => tags.value);

function openTag(id: number) {
  const ids = visibleTags.value.map((t) => t.id);
  const navKey = createRecordset(ids, { returnTo: route.fullPath });
  router.push({ path: `/catalogs/knowledge-tags/${id}`, query: { navKey, returnTo: route.fullPath } });
}

function createTag() {
  const ids = visibleTags.value.map((t) => t.id);
  const navKey = createRecordset(ids, { returnTo: route.fullPath });
  router.push({ path: `/catalogs/knowledge-tags/new`, query: { navKey, returnTo: route.fullPath } });
}

async function loadTags() {
  const requestId = ++lastRequestId;
  loading.value = true;
  error.value = null;
  try {
    const params = new URLSearchParams();
    params.set('sort', 'full_name');
    const q = String(route.query.q || '').trim();
    if (q) params.set('q', q);

    const payload = await jsonApiList('/api/ash/knowledge-tags', params);
    if (requestId !== lastRequestId) return;
    tags.value = (payload.data || []).map(parseRow).filter((t): t is KnowledgeTagRow => Boolean(t));
  } catch (e) {
    console.error(e);
    error.value = e instanceof Error ? e.message : 'Failed to load tags.';
  } finally {
    loading.value = false;
  }
}

let lastRequestId = 0;
let reloadTimer: number | null = null;
function scheduleReload() {
  if (reloadTimer) window.clearTimeout(reloadTimer);
  reloadTimer = window.setTimeout(() => void loadTags(), 250);
}

watch(
  () => route.query.q,
  () => scheduleReload(),
  { immediate: true }
);
</script>
