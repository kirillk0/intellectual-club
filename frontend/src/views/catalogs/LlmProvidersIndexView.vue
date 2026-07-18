<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>LLM Configuration</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <button
            class="icon-button icon-button--labeled primary toolbar-create-button"
            type="button"
            @click="createProvider"
            :disabled="loading"
            aria-label="New provider"
            title="New provider"
          >
            <SvgIcon name="plus" size="16" />
            <span class="icon-button__label">New provider</span>
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <LlmConfigurationNav />

    <PullToRefresh :refresh="loadProviders" :disabled="loading">
      <section class="card stack">
        <label>
          Search
          <input v-model="search" type="search" class="full" placeholder="Search providers" />
        </label>
      </section>

      <InitialRoutePlaceholder v-if="loading" />
      <p v-else-if="error" class="error-text">{{ error }}</p>

      <section v-else class="card stack">
        <div class="list catalog-list">
          <button
            v-for="p in visibleProviders"
            :key="p.id"
            type="button"
            class="row catalog-row"
            @click="openProvider(p.id)"
          >
            <div class="catalog-row__main">
              <div class="catalog-row__title">
                {{ p.name }}
                <span v-if="p.shared_incoming" class="share-indicator" title="Shared with you" aria-label="Shared with you"><SvgIcon name="share-incoming" /></span>
                <span v-else-if="p.shared_outgoing" class="share-indicator" title="Shared with groups" aria-label="Shared with groups"><SvgIcon name="share-outgoing" /></span>
              </div>
              <div class="catalog-row__subtitle">
                {{ providerTypeLabel(p.type) }}
                <span v-if="p.base_url"> · {{ p.base_url }}</span>
              </div>
            </div>
            <div class="catalog-row__meta">
              <span class="badge">{{ providerTypeLabel(p.type) }}</span>
              <span class="catalog-row__chevron" aria-hidden="true">›</span>
            </div>
          </button>
        </div>

        <p v-if="!visibleProviders.length" class="muted">No providers found.</p>
      </section>
    </PullToRefresh>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { useQuery } from '@tanstack/vue-query';
import { useRoute, useRouter } from 'vue-router';
import InitialRoutePlaceholder from '@/components/InitialRoutePlaceholder.vue';
import LlmConfigurationNav from '@/components/LlmConfigurationNav.vue';
import PullToRefresh from '@/components/PullToRefresh.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { jsonApiList, toIntId, type JsonApiResource } from '@/api/jsonApi';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import { serverStateKeys } from '@/features/serverState/queryClient';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import SvgIcon from '@/components/icons/SvgIcon.vue';

type ProviderRow = {
  id: number;
  name: string;
  type: string;
  base_url: string;
  shared_incoming: boolean;
  shared_outgoing: boolean;
};

const route = useRoute();
const router = useRouter();
const stackNav = useStackNavigation();

const providersQuery = useQuery<ProviderRow[]>({
  queryKey: serverStateKeys.collection('llm-providers', 'index'),
  queryFn: ({ signal }) => fetchProviders(signal),
});

const providers = computed(() => providersQuery.data.value ?? []);
const loading = computed(() => providersQuery.isPending.value);
const error = computed(() => {
  if (providersQuery.data.value || !providersQuery.error.value) return null;
  return providersQuery.error.value instanceof Error
    ? providersQuery.error.value.message
    : 'Failed to load providers.';
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

function parseRow(resource: JsonApiResource): ProviderRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return {
    id,
    name: String(attrs.name || '').trim(),
    type: String(attrs.type || '').trim(),
    base_url: String(attrs.base_url || '').trim(),
    shared_incoming: Boolean(attrs.shared_incoming),
    shared_outgoing: Boolean(attrs.shared_outgoing),
  };
}

function providerTypeLabel(type: string) {
  const value = String(type || '').trim();
  return value ? value.replaceAll('_', ' ') : 'provider';
}

const visibleProviders = computed(() => {
  const q = normalize(search.value);
  if (!q) return providers.value;
  return providers.value.filter((p) => normalize(`${p.name} ${p.type} ${p.base_url}`).includes(q));
});

function openProvider(id: number) {
  const ids = visibleProviders.value.map((p) => p.id);
  const recordsetKey = createRecordset(ids);
  stackNav.open({ path: `/catalogs/llm-providers/${id}`, query: { recordsetKey } });
}

function createProvider() {
  const ids = visibleProviders.value.map((p) => p.id);
  const recordsetKey = createRecordset(ids);
  stackNav.open({ path: `/catalogs/llm-providers/new`, query: { recordsetKey } });
}

async function fetchProviders(signal?: AbortSignal): Promise<ProviderRow[]> {
  const params = new URLSearchParams();
  params.set('sort', 'name');
  params.set('fields[llm-providers]', 'name,type,base_url,shared_incoming,shared_outgoing');
  const payload = await jsonApiList('/api/ash/llm-providers', params, { signal });
  return (payload.data || []).map(parseRow).filter((provider): provider is ProviderRow => Boolean(provider));
}

async function loadProviders() {
  await providersQuery.refetch({ cancelRefetch: true });
}
</script>

<style scoped>
.share-indicator {
  margin-left: 8px;
}
</style>
