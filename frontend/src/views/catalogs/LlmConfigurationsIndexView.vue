<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>LLM Configuration</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <button class="icon-button" type="button" @click="openUsage" :disabled="loading" aria-label="Usage" title="Usage">
            <SvgIcon name="bar-chart" />
          </button>
          <button class="primary" type="button" @click="createConfig" :disabled="loading">
            New configuration
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <LlmConfigurationNav />

    <div class="split-wrapper">
      <div class="catalog-split">
        <aside class="catalog-split__sidebar">
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

      <transition name="fade">
        <div v-if="isMobile && tagsOverlayOpen" class="panel-backdrop" @click="closeTagsOverlay"></div>
      </transition>

      <aside v-if="isMobile && tagsOverlayOpen" class="sidebar overlay align-left">
        <LlmConfigurationTagsManagerPanel
          :selectedId="selectedTagId"
          :noTagsSelected="selectedNoTags"
          :hasActiveFilter="hasActiveTagFilter"
          noTagsLabel="No tags"
          @select="selectTag"
          @select-no-tags="selectNoTags"
          @clear-filter="clearTag"
          @changed="loadTagBindings"
        >
          <template #header-extra>
            <button class="panel-toggle" type="button" @click="closeTagsOverlay" aria-label="Hide tags filter">
              <SvgIcon name="chevron-left" />
            </button>
          </template>
        </LlmConfigurationTagsManagerPanel>
      </aside>

      <button
        v-if="isMobile && !tagsOverlayOpen"
        class="panel-toggle floating left"
        :class="{ 'active-filter': hasActiveTagFilter }"
        type="button"
        @click="openTagsOverlay"
        aria-label="Show tags filter"
      >
        #
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import LlmConfigurationNav from '@/components/LlmConfigurationNav.vue';
import LlmConfigurationTagsManagerPanel from '@/components/LlmConfigurationTagsManagerPanel.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { jsonApiList, relationshipId, toIntId, type JsonApiResource } from '@/api/jsonApi';
import { createRecordset } from '@/features/catalogs/model/recordsets';
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

type ConfigTagRow = {
  id: number;
  name: string;
};

const route = useRoute();
const router = useRouter();

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
  const next = { ...route.query };
  delete (next as any).no_tags;

  if (current === id) delete (next as any).tag;
  else (next as any).tag = String(id);

  router.replace({ query: next }).catch(() => {});
  if (isMobile.value) closeTagsOverlay();
}

function selectNoTags() {
  const next = { ...route.query };
  const isSelected = selectedNoTags.value;

  delete (next as any).tag;

  if (isSelected) delete (next as any).no_tags;
  else (next as any).no_tags = 'true';

  router.replace({ query: next }).catch(() => {});
  if (isMobile.value) closeTagsOverlay();
}

function clearTag() {
  const next = { ...route.query };
  delete (next as any).tag;
  delete (next as any).no_tags;
  router.replace({ query: next }).catch(() => {});
  if (isMobile.value) closeTagsOverlay();
}

function openConfig(id: number) {
  const ids = visibleConfigs.value.map((c) => c.id);
  const navKey = createRecordset(ids, { returnTo: route.fullPath });
  router.push({ path: `/catalogs/llm-configurations/${id}`, query: { navKey, returnTo: route.fullPath } });
}

function createConfig() {
  const ids = visibleConfigs.value.map((c) => c.id);
  const navKey = createRecordset(ids, { returnTo: route.fullPath });
  const query: Record<string, unknown> = { navKey, returnTo: route.fullPath };
  if (selectedTagId.value && !selectedNoTags.value) query.defaultTagId = String(selectedTagId.value);
  router.push({ path: `/catalogs/llm-configurations/new`, query });
}

function openUsage() {
  router.push({ path: '/catalogs/llm-configurations/usage', query: { returnTo: route.fullPath } });
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

async function loadProviders() {
  const params = new URLSearchParams();
  params.set('sort', 'name');
  params.set('fields[llm-providers]', 'name');
  const payload = await jsonApiList('/api/ash/llm-providers', params);
  providers.value = (payload.data || []).map(parseProviderRow).filter((p): p is ProviderRow => Boolean(p));
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
  } catch (e) {
    console.error(e);
    error.value = e instanceof Error ? e.message : 'Failed to load configurations.';
  } finally {
    loading.value = false;
  }
}

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
</style>
