<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Bots</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <button class="primary" type="button" @click="createBot" :disabled="loading">
            New bot
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <section class="card stack">
      <div class="catalog-filters">
        <label class="catalog-filters__search">
          Search
          <div class="catalog-search-row">
            <input v-model="search" type="search" class="full" placeholder="Search bots" />
            <button
              type="button"
              class="sort-toggle"
              :class="{ active: botSortModeValue === 'recent_activity' }"
              :aria-label="botSortToggleLabel"
              :title="botSortToggleLabel"
              @click="toggleBotSortMode"
            >
              <SvgIcon :name="botSortModeValue === 'recent_activity' ? 'sort-time' : 'sort-alpha'" />
            </button>
          </div>
        </label>
      </div>
    </section>

    <p v-if="loading" class="muted">Loading…</p>
    <p v-else-if="error" class="error-text">{{ error }}</p>

    <section v-else class="card stack">
      <div class="list catalog-list">
        <button
          v-for="b in visibleBots"
          :key="b.id"
          type="button"
          class="row catalog-row"
          @click="openBot(b.id)"
        >
          <div class="catalog-row__main">
            <div class="catalog-row__title">
              {{ b.name }}
              <span v-if="b.shared_incoming" class="share-indicator" title="Shared with you" aria-label="Shared with you"><SvgIcon name="share-incoming" /></span>
              <span v-else-if="b.shared_outgoing" class="share-indicator" title="Shared with groups" aria-label="Shared with groups"><SvgIcon name="share-outgoing" /></span>
            </div>
            <div class="catalog-row__subtitle">{{ resourcesLabel(b) }}</div>
          </div>
          <ImageThumbnail :image="b.image" :label="b.name" :size="44" :hideWithoutImage="true" />
          <div class="catalog-row__meta">
            <span class="catalog-row__chevron" aria-hidden="true">›</span>
          </div>
        </button>
      </div>

      <p v-if="!visibleBots.length" class="muted">No bots found.</p>
    </section>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import ImageThumbnail from '@/components/ImageThumbnail.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { parseImageAsset } from '@/features/media/image';
import { jsonApiList, toIntId, type JsonApiResource } from '@/api/jsonApi';
import { sortBotsByPreference, useBotSortPreference } from '@/features/bots/model/useBotSortPreference';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import type { ImageAsset } from '@/types/api';

type BotRow = {
  id: number;
  name: string;
  image: ImageAsset | null;
  blocks_count: number;
  tools_count: number;
  shared_incoming: boolean;
  shared_outgoing: boolean;
  created_at?: string | null;
  updated_at?: string | null;
  sort_activity_at?: string | null;
};

const route = useRoute();
const router = useRouter();

const loading = ref(false);
const error = ref<string | null>(null);
const bots = ref<BotRow[]>([]);
const botSortMode = useBotSortPreference();
const botSortModeValue = computed({
  get: () => botSortMode.value,
  set: (value: string) => {
    botSortMode.value = value === 'recent_activity' ? 'recent_activity' : 'name';
  },
});
const botSortToggleLabel = computed(() => {
  return botSortModeValue.value === 'recent_activity'
    ? 'Sort: Recent activity. Switch to Name.'
    : 'Sort: Name. Switch to Recent activity.';
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

function parseCount(value: unknown) {
  if (typeof value === 'number' && Number.isFinite(value) && value >= 0) return value;
  return toIntId(value as string | number | null | undefined) ?? 0;
}

function parseRow(resource: JsonApiResource): BotRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return {
    id,
    name: String(attrs.name || '').trim(),
    image: parseImageAsset(attrs.image),
    blocks_count: parseCount(attrs.blocks_count),
    tools_count: parseCount(attrs.tools_count),
    shared_incoming: Boolean(attrs.shared_incoming),
    shared_outgoing: Boolean(attrs.shared_outgoing),
    created_at: typeof attrs.created_at === 'string' ? attrs.created_at : null,
    updated_at: typeof attrs.updated_at === 'string' ? attrs.updated_at : null,
    sort_activity_at: typeof attrs.sort_activity_at === 'string' ? attrs.sort_activity_at : null,
  };
}

function blocksLabel(count: number) {
  if (count === 1) return '1 block';
  return `${count} blocks`;
}

function toolsLabel(count: number) {
  if (count === 1) return '1 tool';
  return `${count} tools`;
}

function resourcesLabel(bot: BotRow) {
  return `${blocksLabel(bot.blocks_count)} · ${toolsLabel(bot.tools_count)}`;
}

function toggleBotSortMode() {
  botSortModeValue.value = botSortModeValue.value === 'recent_activity' ? 'name' : 'recent_activity';
}

const visibleBots = computed(() => {
  const q = normalize(search.value);
  const filtered = !q
    ? bots.value
    : bots.value.filter((b) => normalize(`${b.name} ${resourcesLabel(b)}`).includes(q));
  return sortBotsByPreference(filtered, botSortMode.value);
});

function openBot(id: number) {
  const ids = visibleBots.value.map((b) => b.id);
  const navKey = createRecordset(ids, { returnTo: route.fullPath });
  router.push({ path: `/catalogs/bots/${id}`, query: { navKey, returnTo: route.fullPath } });
}

function createBot() {
  const ids = visibleBots.value.map((b) => b.id);
  const navKey = createRecordset(ids, { returnTo: route.fullPath });
  router.push({ path: `/catalogs/bots/new`, query: { navKey, returnTo: route.fullPath } });
}

async function loadBots() {
  loading.value = true;
  error.value = null;
  try {
    const botsParams = new URLSearchParams();
    botsParams.set('sort', 'name');
    botsParams.set(
      'fields[bots]',
      'name,blocks_count,tools_count,sort_activity_at,image,shared_incoming,shared_outgoing'
    );

    const botsPayload = await jsonApiList('/api/ash/bots', botsParams);

    bots.value = (botsPayload.data || [])
      .map((resource) => parseRow(resource))
      .filter((b): b is BotRow => Boolean(b));
  } catch (e) {
    console.error(e);
    error.value = e instanceof Error ? e.message : 'Failed to load bots.';
  } finally {
    loading.value = false;
  }
}

onMounted(() => {
  loadBots();
});
</script>

<style scoped>
.catalog-filters {
  display: flex;
  gap: 10px;
  align-items: flex-end;
}

.catalog-filters__search {
  flex: 1;
}

.catalog-search-row {
  display: flex;
  align-items: center;
  gap: 8px;
}

.share-indicator {
  margin-left: 8px;
}

.sort-toggle {
  width: 34px;
  min-width: 34px;
  height: 34px;
  border-radius: 10px;
  border: 1px solid #d2d8e2;
  background: #fff;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: #4b5563;
  padding: 0;
  line-height: 1;
}

.sort-toggle:hover {
  border-color: #b7c5dc;
}

.sort-toggle.active {
  background: #f1f7ff;
  border-color: #b8d6ff;
  color: #1d4ed8;
}

@media (max-width: 720px) {
  .catalog-filters {
    flex-direction: column;
    align-items: stretch;
  }
}
</style>
