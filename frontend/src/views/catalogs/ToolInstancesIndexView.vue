<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Tools</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <button
            class="icon-button icon-button--labeled primary toolbar-create-button"
            type="button"
            @click="createTool"
            :disabled="loading"
            aria-label="New tool"
            title="New tool"
          >
            <SvgIcon name="plus" size="16" />
            <span class="icon-button__label">New tool</span>
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <div class="split-wrapper">
      <div class="catalog-split">
        <aside class="catalog-split__sidebar">
          <section class="card stack tools-types-card">
            <div class="tools-filter-header">
              <strong>Type</strong>
              <button type="button" class="link" :disabled="loading || !hasActiveTypeFilter" @click="clearType">
                Clear
              </button>
            </div>

            <p v-if="loading" class="muted">Loading…</p>
            <div v-else-if="toolTypeOptions.length" class="type-filter-list" aria-label="Filter by type">
              <button
                type="button"
                class="type-filter-option"
                :class="{ active: !selectedToolType }"
                :aria-pressed="!selectedToolType"
                @click="clearType"
              >
                <span class="type-filter-option__label">
                  <span class="type-filter-option__name">All types</span>
                </span>
                <span class="type-filter-option__count">{{ tools.length }}</span>
              </button>

              <button
                v-for="option in toolTypeOptions"
                :key="option.type"
                type="button"
                class="type-filter-option"
                :class="{ active: selectedToolType === option.type }"
                :aria-pressed="selectedToolType === option.type"
                @click="selectType(option.type)"
              >
                <span class="type-filter-option__label">
                  <ToolTypeBadge :type="option.type" :typeTitle="option.title" />
                </span>
                <span class="type-filter-option__count">{{ option.count }}</span>
              </button>
            </div>
            <p v-else class="muted">No tool types.</p>
          </section>
        </aside>

        <main class="catalog-split__main stack">
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
                  <div class="catalog-row__subtitle tool-row__subtitle">
                    <span>{{ t.alias }}</span>
                    <span aria-hidden="true">·</span>
                    <ToolTypeBadge :type="t.type" :typeTitle="t.typeLabel" />
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
        </main>
      </div>

      <transition name="fade">
        <div v-if="isMobile && typesOverlayOpen" class="panel-backdrop" @click="closeTypesOverlay"></div>
      </transition>

      <aside v-if="isMobile && typesOverlayOpen" class="sidebar overlay align-left tools-types-overlay">
        <div class="tools-filter-header">
          <strong>Type</strong>
          <div class="tools-filter-actions">
            <button type="button" class="link" :disabled="loading || !hasActiveTypeFilter" @click="clearType">
              Clear
            </button>
            <button class="panel-toggle" type="button" @click="closeTypesOverlay" aria-label="Hide type filter">
              <SvgIcon name="chevron-left" />
            </button>
          </div>
        </div>

        <p v-if="loading" class="muted">Loading…</p>
        <div v-else-if="toolTypeOptions.length" class="type-filter-list" aria-label="Filter by type">
          <button
            type="button"
            class="type-filter-option"
            :class="{ active: !selectedToolType }"
            :aria-pressed="!selectedToolType"
            @click="clearType"
          >
            <span class="type-filter-option__label">
              <span class="type-filter-option__name">All types</span>
            </span>
            <span class="type-filter-option__count">{{ tools.length }}</span>
          </button>

          <button
            v-for="option in toolTypeOptions"
            :key="option.type"
            type="button"
            class="type-filter-option"
            :class="{ active: selectedToolType === option.type }"
            :aria-pressed="selectedToolType === option.type"
            @click="selectType(option.type)"
          >
            <span class="type-filter-option__label">
              <ToolTypeBadge :type="option.type" :typeTitle="option.title" />
            </span>
            <span class="type-filter-option__count">{{ option.count }}</span>
          </button>
        </div>
        <p v-else class="muted">No tool types.</p>
      </aside>

      <button
        v-if="isMobile && !typesOverlayOpen"
        class="panel-toggle floating left"
        :class="{ 'active-filter': hasActiveTypeFilter }"
        type="button"
        :disabled="loading"
        @click="openTypesOverlay"
        aria-label="Show type filter"
      >
        <SvgIcon name="filter" />
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import ToolTypeBadge from '@/components/ToolTypeBadge.vue';
import { jsonApiList, toIntId, type JsonApiResource } from '@/api/jsonApi';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import { toolTypeLabel } from '@/features/tools/model/toolInstances';
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

type ToolInstanceViewRow = ToolInstanceRow & {
  typeLabel: string;
};

type ToolTypeOption = {
  type: string;
  title: string;
  count: number;
};

const route = useRoute();
const router = useRouter();
const stackNav = useStackNavigation();

const loading = ref(false);
const error = ref<string | null>(null);
const tools = ref<ToolInstanceRow[]>([]);

const search = ref(String(route.query.q || ''));
const selectedToolType = ref(normalizeType(route.query.type));
const isMobile = ref(false);
const typesOverlayOpen = ref(false);
const hasActiveTypeFilter = computed(() => selectedToolType.value.trim().length > 0);

watch(
  () => route.query.q,
  (q) => {
    const next = String(q || '');
    if (next !== search.value) search.value = next;
  }
);

watch(
  () => route.query.type,
  (type) => {
    const next = normalizeType(type);
    if (next !== selectedToolType.value) selectedToolType.value = next;
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

watch(
  () => selectedToolType.value,
  (type) => {
    const normalized = normalizeType(type);
    const next = normalized ? { ...route.query, type: normalized } : { ...route.query };
    if (!normalized) delete (next as any).type;
    router.replace({ query: next }).catch(() => {});
  }
);

function normalize(text: string) {
  return text.trim().toLowerCase();
}

function normalizeType(value: unknown) {
  return String(value ?? '').trim();
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
  return toolTypeLabel({ type: value, type_title: null });
}

const toolTypeOptions = computed<ToolTypeOption[]>(() => {
  const byType = new Map<string, ToolTypeOption>();

  for (const tool of tools.value || []) {
    const type = normalizeType(tool.type);
    if (!type) continue;

    const existing = byType.get(type);
    if (existing) {
      existing.count += 1;
      continue;
    }

    byType.set(type, {
      type,
      title: typeLabel(type),
      count: 1,
    });
  }

  return Array.from(byType.values()).sort(
    (a, b) => a.title.localeCompare(b.title) || a.type.localeCompare(b.type)
  );
});

const allTools = computed<ToolInstanceViewRow[]>(() =>
  tools.value.map((t) => ({ ...t, typeLabel: typeLabel(t.type) }))
);

const visibleTools = computed(() => {
  const q = normalize(search.value);
  const type = normalizeType(selectedToolType.value);

  return allTools.value.filter((t) => {
    if (type && normalizeType(t.type) !== type) return false;
    if (!q) return true;

    return normalize(
      `${t.name} ${t.type} ${t.typeLabel} ${t.server_url} ${t.last_discovered_at} ${t.last_discovery_error}` +
        ` ${t.alias} ${t.description}`
    ).includes(q);
  });
});

watch(
  () => toolTypeOptions.value,
  (options) => {
    if (!selectedToolType.value) return;
    if (!options.some((option) => option.type === selectedToolType.value)) {
      selectedToolType.value = '';
    }
  }
);

watch(
  () => isMobile.value,
  (mobile) => {
    if (!mobile) closeTypesOverlay();
  }
);

function updateIsMobile() {
  isMobile.value = window.matchMedia('(max-width: 860px)').matches;
}

function openTypesOverlay() {
  typesOverlayOpen.value = true;
}

function closeTypesOverlay() {
  typesOverlayOpen.value = false;
}

function selectType(type: string) {
  const normalized = normalizeType(type);
  selectedToolType.value = selectedToolType.value === normalized ? '' : normalized;
  if (isMobile.value) closeTypesOverlay();
}

function clearType() {
  selectedToolType.value = '';
  if (isMobile.value) closeTypesOverlay();
}

function openTool(id: number) {
  const ids = visibleTools.value.map((t) => t.id);
  const recordsetKey = createRecordset(ids);
  stackNav.open({ path: `/catalogs/tools/${id}`, query: { recordsetKey } });
}

function createTool() {
  const ids = visibleTools.value.map((t) => t.id);
  const recordsetKey = createRecordset(ids);
  stackNav.open({ path: `/catalogs/tools/new`, query: { recordsetKey } });
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
  updateIsMobile();
  window.addEventListener('resize', updateIsMobile);
  loadTools();
});

onBeforeUnmount(() => {
  window.removeEventListener('resize', updateIsMobile);
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

.tool-row__subtitle {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
}

.tools-types-card {
  position: sticky;
  top: 68px;
  align-self: start;
  gap: 10px;
  max-height: calc(100vh - 80px);
  min-height: 0;
  overflow: hidden;
}

.tools-types-overlay {
  overflow: hidden;
}

.tools-filter-header,
.tools-filter-actions {
  display: flex;
  align-items: center;
  gap: 8px;
}

.tools-filter-header {
  justify-content: space-between;
}

.tools-filter-actions {
  flex: 0 0 auto;
}

.type-filter-list {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  gap: 4px;
  min-height: 0;
  overflow: auto;
  padding: 2px;
}

.type-filter-option {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  align-items: center;
  gap: 8px;
  width: 100%;
  min-height: 36px;
  padding: 7px 8px;
  border: 0;
  border-radius: 6px;
  background: transparent;
  color: inherit;
  text-align: left;
  cursor: pointer;
}

.type-filter-option:hover,
.type-filter-option:focus-visible,
.type-filter-option.active {
  background: var(--color-info-bg-strong);
  outline: none;
}

.type-filter-option__label {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
  overflow: hidden;
}

.type-filter-option__name {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.type-filter-option__count {
  flex: 0 0 auto;
  min-width: 1.5em;
  color: var(--color-text-subtle);
  font-size: 0.85rem;
  text-align: right;
}
</style>
