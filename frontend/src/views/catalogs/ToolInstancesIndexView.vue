<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Tools</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <button class="primary" type="button" @click="createTool" :disabled="loading">
            New tool
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <section class="card stack">
      <label>
        Search
        <input v-model="search" type="search" class="full" placeholder="Search tools" />
      </label>
    </section>

    <p v-if="loading" class="muted">Loading…</p>
    <p v-else-if="error" class="error-text">{{ error }}</p>

    <section v-else class="card stack">
      <div class="list catalog-list">
        <button
          v-for="t in visibleTools"
          :key="t.id"
          type="button"
          class="row catalog-row"
          @click="openTool(t.id)"
        >
          <div class="catalog-row__main">
            <div class="catalog-row__title">
              {{ t.name || 'Untitled tool' }}
              <span v-if="t.shared_incoming" class="share-indicator" title="Shared with you" aria-label="Shared with you"><SvgIcon name="share-incoming" /></span>
              <span v-else-if="t.shared_outgoing" class="share-indicator" title="Shared with groups" aria-label="Shared with groups"><SvgIcon name="share-outgoing" /></span>
            </div>
            <div class="catalog-row__subtitle">
              {{ t.alias }} · {{ t.typeLabel }}
              <span v-if="t.server_url" class="muted"> · {{ t.server_url }}</span>
            </div>
            <div v-if="t.description" class="muted catalog-row__description">
              {{ t.description }}
            </div>
            <div v-if="t.last_discovery_error" class="error-text" style="margin-top: 4px; font-size: 0.85rem">
              Discovery error: {{ t.last_discovery_error }}
            </div>
            <div v-else-if="t.last_discovered_at" class="muted" style="margin-top: 4px; font-size: 0.85rem">
              Last discovered: {{ formatRelativeDateTime(t.last_discovered_at) }}
            </div>
          </div>
          <div class="catalog-row__meta">
            <span
              v-if="t.type === 'outlet'"
              class="status-dot"
              :class="t.outlet_online ? 'success' : 'danger'"
              :title="t.outlet_online ? 'Online' : 'Offline'"
            />
            <span class="badge">{{ t.max_output_tokens }} max</span>
            <span v-if="t.rps_limit !== null" class="badge">{{ t.rps_limit }} rps</span>
            <span class="catalog-row__chevron" aria-hidden="true">›</span>
          </div>
        </button>
      </div>

      <p v-if="!visibleTools.length" class="muted">No tools found.</p>
    </section>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { jsonApiList, toIntId, type JsonApiResource } from '@/api/jsonApi';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { formatRelativeDateTime } from '@/utils/dates';

type ToolInstanceRow = {
  id: number;
  name: string;
  description: string;
  alias: string;
  type: string;
  server_url: string;
  max_output_tokens: number;
  rps_limit: number | null;
  last_discovered_at: string;
  last_discovery_error: string;
  outlet_online: boolean;
  shared_incoming: boolean;
  shared_outgoing: boolean;
};

const route = useRoute();
const router = useRouter();

const loading = ref(false);
const error = ref<string | null>(null);
const tools = ref<ToolInstanceRow[]>([]);

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

function parseNullableNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null;
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;

  const text = String(value).trim();
  if (!text) return null;

  const parsed = Number(text);
  return Number.isFinite(parsed) ? parsed : null;
}

function parseRow(resource: JsonApiResource): ToolInstanceRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;

  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const config = attrs.config && typeof attrs.config === 'object' ? (attrs.config as Record<string, unknown>) : {};

  return {
    id,
    name: String(attrs.name || '').trim(),
    description: String(attrs.description || '').trim(),
    alias: String(attrs.alias || '').trim(),
    type: String(attrs.type || '').trim(),
    server_url: String(config.server_url || '').trim(),
    max_output_tokens:
      typeof attrs.max_output_tokens === 'number'
        ? attrs.max_output_tokens
        : Number(attrs.max_output_tokens || 0),
    rps_limit: parseNullableNumber(attrs.rps_limit),
    last_discovered_at: String(attrs.last_discovered_at || '').trim(),
    last_discovery_error: String(attrs.last_discovery_error || '').trim(),
    outlet_online: Boolean(attrs.outlet_online),
    shared_incoming: Boolean(attrs.shared_incoming),
    shared_outgoing: Boolean(attrs.shared_outgoing),
  };
}

function typeLabel(value: string) {
  const t = String(value || '').trim();
  if (!t) return 'tool';
  return t;
}

const visibleTools = computed(() => {
  const q = normalize(search.value);
  const all = tools.value.map((t) => ({ ...t, typeLabel: typeLabel(t.type) }));
  if (!q) return all;

  return all.filter((t) =>
    normalize(
      `${t.name} ${t.type} ${t.server_url} ${t.last_discovered_at} ${t.last_discovery_error}` +
        ` ${t.alias} ${t.description}`
    ).includes(q)
  );
});

function openTool(id: number) {
  const ids = visibleTools.value.map((t) => t.id);
  const navKey = createRecordset(ids, { returnTo: route.fullPath });
  router.push({ path: `/catalogs/tools/${id}`, query: { navKey, returnTo: route.fullPath } });
}

function createTool() {
  const ids = visibleTools.value.map((t) => t.id);
  const navKey = createRecordset(ids, { returnTo: route.fullPath });
  router.push({ path: `/catalogs/tools/new`, query: { navKey, returnTo: route.fullPath } });
}

async function loadTools() {
  loading.value = true;
  error.value = null;

  try {
    const params = new URLSearchParams();
    params.set('sort', 'name');
    params.set(
      'fields[tool-instances]',
      'name,description,alias,type,config,max_output_tokens,rps_limit,last_discovered_at,last_discovery_error,outlet_online,shared_incoming,shared_outgoing'
    );
    const payload = await jsonApiList('/api/ash/tool-instances', params);
    tools.value = (payload.data || []).map(parseRow).filter((t): t is ToolInstanceRow => Boolean(t));
  } catch (e) {
    console.error(e);
    error.value = e instanceof Error ? e.message : 'Failed to load tools.';
  } finally {
    loading.value = false;
  }
}

onMounted(() => {
  loadTools();
});
</script>

<style scoped>
.share-indicator {
  margin-left: 8px;
}

.catalog-row__description {
  display: -webkit-box;
  margin-top: 4px;
  overflow: hidden;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
}
</style>
