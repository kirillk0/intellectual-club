<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Knowledge Blocks</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <button class="primary" type="button" @click="createBlock" :disabled="loading">
            New block
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <div class="split-wrapper">
      <div class="catalog-split">
        <aside class="catalog-split__sidebar">
          <KnowledgeTagsManagerPanel
            :selectedId="selectedTagId"
            :noTagsSelected="selectedNoTags"
            :hasActiveFilter="hasActiveTagFilter"
            noTagsLabel="No tags"
            storageKey="ic.knowledge_tags.tree.open_state.v1"
            :defaultExpandDepth="2"
            @select="selectTag"
            @select-no-tags="selectNoTags"
            @clear-filter="clearTag"
          />
        </aside>

        <main class="catalog-split__main stack">
          <section class="card stack">
            <label>
              Search
              <input v-model="search" type="search" class="full" placeholder="Search blocks" />
            </label>
          </section>

          <p v-if="loading" class="muted">Loading…</p>
          <p v-else-if="error" class="error-text">{{ error }}</p>

          <section v-else class="card stack">
            <div class="list catalog-list">
              <button
                v-for="b in visibleBlocks"
                :key="b.id"
                type="button"
                class="row catalog-row"
                @click="openBlock(b.id)"
              >
                <div class="catalog-row__main">
                <div class="catalog-row__title">
                  {{ b.name }}
                  <span v-if="b.shared_incoming" class="share-indicator" title="Shared with you" aria-label="Shared with you"><SvgIcon name="share-incoming" /></span>
                  <span v-else-if="b.shared_outgoing" class="share-indicator" title="Shared with groups" aria-label="Shared with groups"><SvgIcon name="share-outgoing" /></span>
                </div>
                  <div class="catalog-row__subtitle">
                    {{ formatVersion(b.version) || 'No version' }}
                  </div>
                </div>
                <ImageThumbnail :image="b.image" :label="b.name" :size="44" :hideWithoutImage="true" />
                <div class="catalog-row__meta">
                  <span class="badge">{{ b.tokenCount }} tokens</span>
                  <span class="catalog-row__chevron" aria-hidden="true">›</span>
                </div>
              </button>
            </div>

            <p v-if="!visibleBlocks.length" class="muted">No blocks found.</p>
          </section>
        </main>
      </div>

      <transition name="fade">
        <div v-if="isMobile && tagsOverlayOpen" class="panel-backdrop" @click="closeTagsOverlay"></div>
      </transition>

      <aside v-if="isMobile && tagsOverlayOpen" class="sidebar overlay align-left">
        <KnowledgeTagsManagerPanel
          :selectedId="selectedTagId"
          :noTagsSelected="selectedNoTags"
          :hasActiveFilter="hasActiveTagFilter"
          noTagsLabel="No tags"
          storageKey="ic.knowledge_tags.tree.open_state.v1"
          :defaultExpandDepth="2"
          @select="selectTag"
          @select-no-tags="selectNoTags"
          @clear-filter="clearTag"
        >
          <template #header-extra>
            <button class="panel-toggle" type="button" @click="closeTagsOverlay" aria-label="Hide tags filter">
              <SvgIcon name="chevron-left" />
            </button>
          </template>
        </KnowledgeTagsManagerPanel>
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
import ImageThumbnail from '@/components/ImageThumbnail.vue';
import KnowledgeTagsManagerPanel from '@/components/KnowledgeTagsManagerPanel.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { parseImageAsset } from '@/features/media/image';
import { jsonApiList, toIntId, type JsonApiResource } from '@/api/jsonApi';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import type { ImageAsset } from '@/types/api';

type KnowledgeBlockRow = {
  id: number;
  name: string;
  image: ImageAsset | null;
  version: string;
  tokenCount: number;
  shared_incoming: boolean;
  shared_outgoing: boolean;
};

const route = useRoute();
const router = useRouter();

const loading = ref(false);
const error = ref<string | null>(null);
const blocks = ref<KnowledgeBlockRow[]>([]);

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
const selectedNoTags = computed(() => parseBooleanQuery(route.query.no_tags));
const hasActiveTagFilter = computed(() => Boolean(selectedTagId.value) || selectedNoTags.value);

function parseBooleanQuery(value: unknown): boolean {
  const source = Array.isArray(value) ? value[0] : value;
  if (typeof source === 'boolean') return source;
  if (typeof source === 'number') return source !== 0;
  if (typeof source !== 'string') return false;
  const normalized = source.trim().toLowerCase();
  return normalized === '1' || normalized === 'true' || normalized === 'yes' || normalized === 'on';
}

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

function formatVersion(value: string) {
  const text = String(value || '').trim();
  if (!text) return '';
  if (/^v\\d+/i.test(text)) return text;
  if (/^\\d+$/.test(text)) return `v${text}`;
  return text;
}

function parseRow(resource: JsonApiResource): KnowledgeBlockRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return {
    id,
    name: String(attrs.name || '').trim(),
    image: parseImageAsset(attrs.image),
    version: String(attrs.version || '').trim(),
    tokenCount: Number(attrs.token_count || 0),
    shared_incoming: Boolean(attrs.shared_incoming),
    shared_outgoing: Boolean(attrs.shared_outgoing),
  };
}

const visibleBlocks = computed(() => blocks.value);

function selectTag(id: number) {
  const current = selectedTagId.value;
  const next = { ...route.query };
  delete (next as any).no_tags;

  if (current === id) {
    delete (next as any).tag;
  } else {
    (next as any).tag = String(id);
  }

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

function openBlock(id: number) {
  const ids = visibleBlocks.value.map((b) => b.id);
  const navKey = createRecordset(ids, { returnTo: route.fullPath });
  router.push({ path: `/catalogs/knowledge-blocks/${id}`, query: { navKey, returnTo: route.fullPath } });
}

function createBlock() {
  const ids = visibleBlocks.value.map((b) => b.id);
  const navKey = createRecordset(ids, { returnTo: route.fullPath });
  const query: Record<string, unknown> = { navKey, returnTo: route.fullPath };
  if (selectedTagId.value && !selectedNoTags.value) query.defaultTagId = String(selectedTagId.value);
  router.push({ path: `/catalogs/knowledge-blocks/new`, query });
}

let lastBlocksRequestId = 0;

async function loadBlocks() {
  const requestId = ++lastBlocksRequestId;
  loading.value = true;
  error.value = null;
  try {
    const params = new URLSearchParams();
    params.set('sort', 'name');
    params.set('fields[knowledge-blocks]', 'name,version,token_count,image,shared_incoming,shared_outgoing');
    const q = String(route.query.q || '').trim();
    if (q) params.set('q', q);
    if (selectedNoTags.value) params.set('no_tags', 'true');
    else if (selectedTagId.value) params.set('tag_id', String(selectedTagId.value));

    const payload = await jsonApiList('/api/ash/knowledge-blocks', params);
    if (requestId !== lastBlocksRequestId) return;

    blocks.value = (payload.data || []).map(parseRow).filter((b): b is KnowledgeBlockRow => Boolean(b));
  } catch (e) {
    console.error(e);
    error.value = e instanceof Error ? e.message : 'Failed to load blocks.';
  } finally {
    loading.value = false;
  }
}

let reloadTimer: number | null = null;
function scheduleReloadBlocks() {
  if (reloadTimer) window.clearTimeout(reloadTimer);
  reloadTimer = window.setTimeout(() => void loadBlocks(), 250);
}

onMounted(() => {
  updateIsMobile();
  window.addEventListener('resize', updateIsMobile);
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

watch(
  () => [route.query.q, route.query.tag, route.query.no_tags],
  () => {
    scheduleReloadBlocks();
  },
  { immediate: true }
);
</script>

<style scoped>
.share-indicator {
  margin-left: 8px;
}
</style>
