<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>LLM Configuration</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <button class="icon-button icon-button--labeled" type="button" @click="openUsage" :disabled="loading" aria-label="Usage" title="Usage">
            <SvgIcon name="bar-chart" />
            <span class="icon-button__label">Usage</span>
          </button>
          <button
            class="icon-button icon-button--labeled primary toolbar-create-button"
            type="button"
            @click="createConfig"
            :disabled="loading"
            aria-label="New configuration"
            title="New configuration"
          >
            <SvgIcon name="plus" size="16" />
            <span class="icon-button__label">New configuration</span>
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <LlmConfigurationNav />

    <div class="split-wrapper">
      <PullToRefresh :refresh="loadData" :disabled="loading">
        <div class="catalog-split">
        <aside class="catalog-split__sidebar">
          <div class="llm-configurations-sidebar-stack">
            <section class="card stack llm-config-provider-filter-card">
              <div class="llm-config-filter-header">
                <strong>Provider</strong>
                <button type="button" class="link" :disabled="loading || !hasActiveProviderFilter" @click="clearProvider">
                  Clear
                </button>
              </div>

              <p v-if="loading" class="muted">Loading…</p>
              <div v-else class="provider-filter-list" aria-label="Filter by provider">
                <button
                  type="button"
                  class="provider-filter-option"
                  :class="{ active: !selectedProviderFilter }"
                  :aria-pressed="!selectedProviderFilter"
                  @click="clearProvider"
                >
                  <span class="provider-filter-option__name">All providers</span>
                  <span class="provider-filter-option__count">{{ configs.length }}</span>
                </button>

                <button
                  v-if="hasNoProviderConfigs || selectedNoProvider"
                  type="button"
                  class="provider-filter-option"
                  :class="{ active: selectedNoProvider }"
                  :aria-pressed="selectedNoProvider"
                  @click="selectProvider('none')"
                >
                  <span class="provider-filter-option__name">No provider</span>
                  <span class="provider-filter-option__count">{{ noProviderConfigCount }}</span>
                </button>

                <button
                  v-for="provider in providerFilterOptions"
                  :key="provider.id"
                  type="button"
                  class="provider-filter-option"
                  :class="{ active: selectedProviderId === provider.id }"
                  :aria-pressed="selectedProviderId === provider.id"
                  @click="selectProvider(String(provider.id))"
                >
                  <span class="provider-filter-option__name" data-i18n-ignore>{{ provider.name }}</span>
                  <span class="provider-filter-option__count">{{ providerConfigCount(provider.id) }}</span>
                </button>
              </div>
            </section>

            <LlmConfigurationTagsManagerPanel
              :selectedId="selectedTagId"
              :noTagsSelected="selectedNoTags"
              :hasActiveFilter="hasActiveTagFilter"
              noTagsLabel="No tags"
              @select="selectTag"
              @select-no-tags="selectNoTags"
              @clear-filter="clearTag"
              @changed="loadTagBindings"
            />
          </div>
        </aside>

        <main class="catalog-split__main stack">
          <section class="card stack">
            <label>
              Search
              <input v-model="search" type="search" class="full" placeholder="Search configurations" />
            </label>
          </section>

          <p v-if="loading" class="muted">Loading…</p>
          <p v-else-if="error" class="error-text">{{ error }}</p>

          <section v-else class="card stack">
            <div class="list catalog-list">
              <button
                v-for="c in visibleConfigs"
                :key="c.id"
                type="button"
                class="row catalog-row"
                @click="openConfig(c.id)"
              >
                <div class="catalog-row__main">
                  <div class="catalog-row__title">
                    <span class="catalog-row__title-text">{{ configLabel(c) }}</span>
                    <span
                      v-if="c.shared_incoming"
                      class="share-indicator"
                      title="Shared with you"
                      aria-label="Shared with you"
                    >
                      <SvgIcon name="share-incoming" />
                    </span>
                    <span
                      v-else-if="c.shared_outgoing"
                      class="share-indicator"
                      title="Shared with groups"
                      aria-label="Shared with groups"
                    >
                      <SvgIcon name="share-outgoing" />
                    </span>
                    <span class="catalog-row__title-meta">{{ providerName(c.provider_id) }}</span>
                  </div>
                  <div v-if="configTags(c.id).length" class="catalog-row__tags">
                    <span v-for="tag in configTags(c.id)" :key="`${c.id}-${tag.id}`" class="badge">
                      {{ tag.name }}
                    </span>
                  </div>
                </div>
                <div class="catalog-row__meta">
                  <span class="status-dot" :class="c.enabled ? 'success' : 'danger'" :title="c.enabled ? 'Enabled' : 'Disabled'" />
                  <span class="catalog-row__chevron" aria-hidden="true">›</span>
                </div>
              </button>
            </div>

            <p v-if="!visibleConfigs.length" class="muted">No configurations found.</p>
          </section>
        </main>
        </div>
      </PullToRefresh>

      <transition name="fade">
        <div v-if="isMobile && tagsOverlayOpen" class="panel-backdrop" @click="closeTagsOverlay"></div>
      </transition>

      <aside v-if="isMobile && tagsOverlayOpen" class="sidebar overlay align-left llm-configurations-filter-overlay">
        <section class="card stack llm-config-provider-filter-card">
          <div class="llm-config-filter-header">
            <strong>Provider</strong>
            <div class="llm-config-filter-header__actions">
              <button type="button" class="link" :disabled="loading || !hasActiveProviderFilter" @click="clearProvider">
                Clear
              </button>
              <button class="panel-toggle" type="button" @click="closeTagsOverlay" aria-label="Hide filters">
                <SvgIcon name="chevron-left" />
              </button>
            </div>
          </div>

          <p v-if="loading" class="muted">Loading…</p>
          <div v-else class="provider-filter-list" aria-label="Filter by provider">
            <button
              type="button"
              class="provider-filter-option"
              :class="{ active: !selectedProviderFilter }"
              :aria-pressed="!selectedProviderFilter"
              @click="clearProvider"
            >
              <span class="provider-filter-option__name">All providers</span>
              <span class="provider-filter-option__count">{{ configs.length }}</span>
            </button>

            <button
              v-if="hasNoProviderConfigs || selectedNoProvider"
              type="button"
              class="provider-filter-option"
              :class="{ active: selectedNoProvider }"
              :aria-pressed="selectedNoProvider"
              @click="selectProvider('none')"
            >
              <span class="provider-filter-option__name">No provider</span>
              <span class="provider-filter-option__count">{{ noProviderConfigCount }}</span>
            </button>

            <button
              v-for="provider in providerFilterOptions"
              :key="provider.id"
              type="button"
              class="provider-filter-option"
              :class="{ active: selectedProviderId === provider.id }"
              :aria-pressed="selectedProviderId === provider.id"
              @click="selectProvider(String(provider.id))"
            >
              <span class="provider-filter-option__name" data-i18n-ignore>{{ provider.name }}</span>
              <span class="provider-filter-option__count">{{ providerConfigCount(provider.id) }}</span>
            </button>
          </div>
        </section>

        <LlmConfigurationTagsManagerPanel
          :selectedId="selectedTagId"
          :noTagsSelected="selectedNoTags"
          :hasActiveFilter="hasActiveTagFilter"
          noTagsLabel="No tags"
          @select="selectTag"
          @select-no-tags="selectNoTags"
          @clear-filter="clearTag"
          @changed="loadTagBindings"
        />
      </aside>

      <button
        v-if="isMobile && !tagsOverlayOpen"
        class="panel-toggle floating left"
        :class="{ 'active-filter': hasActiveCatalogFilter }"
        type="button"
        @click="openTagsOverlay"
        aria-label="Show filters"
      >
        <SvgIcon name="filter" />
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRoute, useRouter, type LocationQueryRaw } from 'vue-router';
import LlmConfigurationNav from '@/components/LlmConfigurationNav.vue';
import LlmConfigurationTagsManagerPanel from '@/components/LlmConfigurationTagsManagerPanel.vue';
import PullToRefresh from '@/components/PullToRefresh.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { jsonApiGet, jsonApiList, relationshipId, toIntId, type JsonApiResource } from '@/api/jsonApi';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import { useEntityChanges, useLiveEntityRows } from '@/features/entities/entityChanges';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import SvgIcon from '@/components/icons/SvgIcon.vue';

type ConfigRow = {
  id: number;
  model_name: string;
  note: string;
  enabled: boolean;
  provider_id: number | null;
  shared_incoming: boolean;
  shared_outgoing: boolean;
};

type ProviderRow = {
  id: number;
  name: string;
};

type ProviderFilterOption = ProviderRow;

type ConfigTagRow = {
  id: number;
  name: string;
};

const route = useRoute();
const router = useRouter();
const stackNav = useStackNavigation();

const loading = ref(false);
const error = ref<string | null>(null);
const configs = ref<ConfigRow[]>([]);
const providers = ref<ProviderRow[]>([]);
const tagsByConfigId = ref(new Map<number, ConfigTagRow[]>());

const search = ref(String(route.query.q || ''));

const isMobile = ref(false);
const tagsOverlayOpen = ref(false);

function updateIsMobile() {
  isMobile.value = window.matchMedia('(max-width: 860px)').matches;
}

function openTagsOverlay() {
  tagsOverlayOpen.value = true;
}

function closeTagsOverlay() {
  tagsOverlayOpen.value = false;
}

const selectedTagId = computed(() => toIntId(route.query.tag as any));

function parseBooleanQuery(value: unknown): boolean {
  const source = Array.isArray(value) ? value[0] : value;
  if (typeof source === 'boolean') return source;
  if (typeof source === 'number') return source !== 0;
  if (typeof source !== 'string') return false;
  const normalized = source.trim().toLowerCase();
  return normalized === '1' || normalized === 'true' || normalized === 'yes' || normalized === 'on';
}

const selectedNoTags = computed(() => parseBooleanQuery(route.query.no_tags));
const hasActiveTagFilter = computed(() => Boolean(selectedTagId.value) || selectedNoTags.value);

function normalizeProviderFilter(value: unknown): string {
  const source = Array.isArray(value) ? value[0] : value;
  if (String(source || '').trim().toLowerCase() === 'none') return 'none';

  const id = toIntId(source as any);
  return id ? String(id) : '';
}

const selectedProviderFilter = computed(() => normalizeProviderFilter(route.query.provider));
const selectedProviderId = computed(() => {
  const value = selectedProviderFilter.value;
  if (!value || value === 'none') return null;
  return Number(value);
});
const selectedNoProvider = computed(() => selectedProviderFilter.value === 'none');
const hasActiveProviderFilter = computed(() => Boolean(selectedProviderFilter.value));
const hasActiveCatalogFilter = computed(() => hasActiveTagFilter.value || hasActiveProviderFilter.value);

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

function parseRow(resource: JsonApiResource): ConfigRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return {
    id,
    model_name: String(attrs.model_name || '').trim(),
    note: String(attrs.note || '').trim(),
    enabled: Boolean(attrs.enabled),
    provider_id:
      (typeof attrs.provider_id === 'number' ? attrs.provider_id : toIntId(attrs.provider_id as any)) ??
      relationshipId(resource, 'provider'),
    shared_incoming: Boolean(attrs.shared_incoming),
    shared_outgoing: Boolean(attrs.shared_outgoing),
  };
}

function parseProviderRow(resource: JsonApiResource): ProviderRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return {
    id,
    name: String(attrs.name || '').trim(),
  };
}

const providersById = computed(() => {
  const map = new Map<number, string>();
  for (const provider of providers.value) map.set(provider.id, provider.name);
  return map;
});

function providerName(providerId: number | null) {
  if (!providerId) return 'No provider';
  return providersById.value.get(providerId) || `Provider #${providerId}`;
}

const hasNoProviderConfigs = computed(() => configs.value.some((config) => !config.provider_id));
const noProviderConfigCount = computed(() => configs.value.filter((config) => !config.provider_id).length);

const providerConfigCounts = computed(() => {
  const counts = new Map<number, number>();

  for (const config of configs.value) {
    const providerId = config.provider_id;
    if (!providerId) continue;
    counts.set(providerId, (counts.get(providerId) || 0) + 1);
  }

  return counts;
});

const providerFilterOptions = computed<ProviderFilterOption[]>(() => {
  const byId = new Map<number, ProviderFilterOption>();

  for (const provider of providers.value) byId.set(provider.id, provider);

  for (const config of configs.value) {
    const id = config.provider_id;
    if (!id || byId.has(id)) continue;
    byId.set(id, { id, name: providerName(id) });
  }

  return Array.from(byId.values()).sort((a, b) => a.name.localeCompare(b.name) || a.id - b.id);
});

function providerConfigCount(providerId: number) {
  return providerConfigCounts.value.get(providerId) || 0;
}

function configLabel(config: ConfigRow) {
  const note = config.note.trim();
  if (!note) return config.model_name;
  return `${config.model_name} (${note})`;
}

function configTags(configId: number) {
  return tagsByConfigId.value.get(configId) || [];
}

const visibleConfigs = computed(() => {
  const q = normalize(search.value);

  return configs.value.filter((config) => {
    const matchesProvider = selectedNoProvider.value
      ? !config.provider_id
      : selectedProviderId.value
        ? config.provider_id === selectedProviderId.value
        : true;

    if (!matchesProvider) return false;

    const tags = configTags(config.id);
    const tagIds = tags.map((tag) => tag.id);
    const matchesTag = selectedNoTags.value
      ? tagIds.length === 0
      : selectedTagId.value
        ? tagIds.includes(selectedTagId.value)
        : true;

    if (!matchesTag) return false;

    if (!q) return true;

    const haystack = [
      configLabel(config),
      providerName(config.provider_id),
      ...tags.map((tag) => tag.name),
    ].join(' ');

    return normalize(haystack).includes(q);
  });
});

function selectTag(id: number) {
  const current = selectedTagId.value;
  const next: LocationQueryRaw = { ...route.query };
  delete next.no_tags;

  if (current === id) delete next.tag;
  else next.tag = String(id);

  router.replace({ query: next }).catch(() => {});
  if (isMobile.value) closeTagsOverlay();
}

function selectNoTags() {
  const next: LocationQueryRaw = { ...route.query };
  const isSelected = selectedNoTags.value;

  delete next.tag;

  if (isSelected) delete next.no_tags;
  else next.no_tags = 'true';

  router.replace({ query: next }).catch(() => {});
  if (isMobile.value) closeTagsOverlay();
}

function clearTag() {
  const next: LocationQueryRaw = { ...route.query };
  delete next.tag;
  delete next.no_tags;
  router.replace({ query: next }).catch(() => {});
  if (isMobile.value) closeTagsOverlay();
}

function selectProvider(value: string) {
  const provider = normalizeProviderFilter(value);
  const next: LocationQueryRaw = { ...route.query };

  delete next.provider;
  if (provider && provider !== selectedProviderFilter.value) next.provider = provider;

  router.replace({ query: next }).catch(() => {});
}

function clearProvider() {
  const next: LocationQueryRaw = { ...route.query };
  delete next.provider;
  router.replace({ query: next }).catch(() => {});
}

function ensureSelectedProviderIsAvailable() {
  const id = selectedProviderId.value;
  if (!id) return;
  if (providerFilterOptions.value.some((provider) => provider.id === id)) return;

  const next: LocationQueryRaw = { ...route.query };
  delete next.provider;
  router.replace({ query: next }).catch(() => {});
}

function openConfig(id: number) {
  const ids = visibleConfigs.value.map((c) => c.id);
  const recordsetKey = createRecordset(ids);
  stackNav.open({ path: `/catalogs/llm-configurations/${id}`, query: { recordsetKey } });
}

function createConfig() {
  const ids = visibleConfigs.value.map((c) => c.id);
  const recordsetKey = createRecordset(ids);
  const query: LocationQueryRaw = { recordsetKey };
  if (selectedTagId.value && !selectedNoTags.value) query.defaultTagId = String(selectedTagId.value);
  stackNav.open({ path: `/catalogs/llm-configurations/new`, query });
}

function openUsage() {
  stackNav.open({ path: '/catalogs/llm-configurations/usage' });
}

async function loadConfigs() {
  const params = new URLSearchParams();
  params.set('sort', 'model_name');
  params.set(
    'fields[llm-configurations]',
    'provider_id,model_name,note,enabled,shared_incoming,shared_outgoing'
  );
  const payload = await jsonApiList('/api/ash/llm-configurations', params);
  configs.value = (payload.data || []).map(parseRow).filter((c): c is ConfigRow => Boolean(c));
}

async function fetchConfigRow(id: number) {
  try {
    const params = new URLSearchParams();
    params.set(
      'fields[llm-configurations]',
      'provider_id,model_name,note,enabled,shared_incoming,shared_outgoing'
    );
    const payload = await jsonApiGet(`/api/ash/llm-configurations/${id}`, params);
    return parseRow(payload.data);
  } catch (error) {
    console.warn('Failed to refresh configuration row.', error);
    return null;
  }
}

async function loadProviders() {
  const params = new URLSearchParams();
  params.set('sort', 'name');
  params.set('fields[llm-providers]', 'name');
  const payload = await jsonApiList('/api/ash/llm-providers', params);
  providers.value = (payload.data || []).map(parseProviderRow).filter((p): p is ProviderRow => Boolean(p));
}

async function fetchProviderRow(id: number) {
  try {
    const params = new URLSearchParams();
    params.set('fields[llm-providers]', 'name');
    const payload = await jsonApiGet(`/api/ash/llm-providers/${id}`, params);
    return parseProviderRow(payload.data);
  } catch (error) {
    console.warn('Failed to refresh provider row.', error);
    return null;
  }
}

async function loadTagBindings() {
  try {
    const params = new URLSearchParams();
    params.set('sort', 'llm_configuration_id');
    params.set('include', 'llm_configuration_tag');
    params.set('fields[llm-configuration-tag-bindings]', 'llm_configuration_id,llm_configuration_tag_id');
    params.set('fields[llm-configuration-tags]', 'name');

    const payload = await jsonApiList('/api/ash/llm-configuration-tag-bindings', params);

    const tagsById = new Map<number, ConfigTagRow>();

    for (const resource of payload.included || []) {
      if (resource.type !== 'llm-configuration-tags') continue;
      const id = toIntId(resource.id);
      if (!id) continue;
      const attrs = (resource.attributes || {}) as Record<string, unknown>;
      tagsById.set(id, { id, name: String(attrs.name || '').trim() });
    }

    const next = new Map<number, ConfigTagRow[]>();

    for (const resource of payload.data || []) {
      const attrs = (resource.attributes || {}) as Record<string, unknown>;
      const configId =
        relationshipId(resource, 'llm_configuration') ??
        (typeof attrs.llm_configuration_id === 'number'
          ? attrs.llm_configuration_id
          : toIntId(attrs.llm_configuration_id as any));
      const tagId =
        relationshipId(resource, 'llm_configuration_tag') ??
        (typeof attrs.llm_configuration_tag_id === 'number'
          ? attrs.llm_configuration_tag_id
          : toIntId(attrs.llm_configuration_tag_id as any));

      if (!configId || !tagId) continue;

      const tag = tagsById.get(tagId) || { id: tagId, name: `Tag #${tagId}` };
      const current = next.get(configId) || [];
      current.push(tag);
      next.set(configId, current);
    }

    for (const [configId, tags] of next.entries()) {
      tags.sort((a, b) => a.name.localeCompare(b.name) || a.id - b.id);
      next.set(configId, tags);
    }

    tagsByConfigId.value = next;
  } catch (e) {
    console.error(e);
  }
}

async function loadData() {
  loading.value = true;
  error.value = null;
  try {
    await Promise.all([loadConfigs(), loadProviders(), loadTagBindings()]);
    ensureSelectedProviderIsAvailable();
  } catch (e) {
    console.error(e);
    error.value = e instanceof Error ? e.message : 'Failed to load configurations.';
  } finally {
    loading.value = false;
  }
}

useLiveEntityRows(configs, {
  kind: 'llm-configuration',
  getId: (row) => row.id,
  resolveRow: (change) => fetchConfigRow(change.id),
  compare: (a, b) => configLabel(a).localeCompare(configLabel(b)) || a.id - b.id,
});

useLiveEntityRows(providers, {
  kind: 'llm-provider',
  getId: (row) => row.id,
  resolveRow: (change) => fetchProviderRow(change.id),
  compare: (a, b) => a.name.localeCompare(b.name) || a.id - b.id,
});

useEntityChanges((change) => {
  if (change.kind !== 'llm-configuration') return;
  if (change.operation === 'delete') {
    const next = new Map(tagsByConfigId.value);
    next.delete(change.id);
    tagsByConfigId.value = next;
    return;
  }

  void loadTagBindings();
});

onMounted(() => {
  updateIsMobile();
  window.addEventListener('resize', updateIsMobile);
  void loadData();
});

onBeforeUnmount(() => {
  window.removeEventListener('resize', updateIsMobile);
});

watch(
  () => isMobile.value,
  (mobile) => {
    if (!mobile) closeTagsOverlay();
  }
);
</script>

<style scoped>
.share-indicator {
  margin-left: 8px;
}
</style>

<style scoped>
.catalog-row__title {
  display: flex;
  align-items: baseline;
  gap: 8px;
  min-width: 0;
}

.catalog-row__title-text {
  min-width: 0;
}

.catalog-row__title-meta {
  color: var(--muted-text-color, var(--color-base-content));
  font-size: 0.9em;
  font-weight: 400;
  opacity: 0.72;
  white-space: nowrap;
}

.catalog-row__tags {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 8px;
}

.llm-configurations-sidebar-stack {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.llm-configurations-filter-overlay {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.llm-config-filter-header,
.llm-config-filter-header__actions {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.provider-filter-list {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.provider-filter-option {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  width: 100%;
  min-height: 36px;
  padding: 7px 8px;
  border-color: transparent;
  background: transparent;
  text-align: left;
}

.provider-filter-option:hover,
.provider-filter-option:focus-visible,
.provider-filter-option.active {
  background: var(--color-surface-muted);
  border-color: var(--color-border-strong);
}

.provider-filter-option.active {
  color: var(--color-primary);
}

.provider-filter-option__name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  min-width: 0;
}

.provider-filter-option__count {
  flex: 0 0 auto;
  color: var(--color-text-muted);
  font-size: 0.82rem;
}
</style>
