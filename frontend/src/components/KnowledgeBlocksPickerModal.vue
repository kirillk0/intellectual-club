<template>
  <Teleport to="body">
    <div v-if="open" class="modal-backdrop" @click.self="close">
      <div class="modal knowledge-block-picker" role="dialog" aria-modal="true">
        <div class="picker-header">
          <strong>{{ title }}</strong>
          <button type="button" aria-label="Close" @click="close">Close</button>
        </div>

        <div class="picker-body">
          <div class="split-wrapper picker-split-wrapper">
            <div class="catalog-split picker-split">
              <aside class="catalog-split__sidebar">
                <section class="card stack picker-tags-card">
                  <div style="display: flex; align-items: center; justify-content: space-between; gap: 8px">
                    <strong>Tags</strong>
                    <button type="button" class="link" :disabled="!hasActiveTagFilter" @click="clearTag">
                      Clear
                    </button>
                  </div>

                  <p v-if="tagsLoading" class="muted">Loading…</p>
                  <p v-else-if="tagsError" class="error-text">{{ tagsError }}</p>
                  <KnowledgeTagsTree
                    v-else
                    :tags="tags"
                    :selectedId="selectedTagId"
                    :showNoTagsOption="true"
                    :noTagsSelected="selectedNoTags"
                    noTagsLabel="No tags"
                    storageKey="ic.knowledge_tags.tree.open_state.v1"
                    :defaultExpandDepth="2"
                    @select="selectTag"
                    @select-no-tags="selectNoTags"
                  />

                  <p v-if="!tagsLoading && !tagsError && !tags.length" class="muted">No tags.</p>
                </section>
              </aside>

              <main class="catalog-split__main stack picker-main">
                <div class="picker-controls">
                  <input
                    v-model="query"
                    type="search"
                    class="full"
                    placeholder="Search blocks"
                    aria-label="Search blocks"
                  />
                  <button v-if="query" type="button" @click="query = ''">Clear</button>
                  <button
                    v-if="isMobile && !tagsOverlayOpen"
                    class="panel-toggle"
                    :class="{ 'active-filter': hasActiveTagFilter }"
                    type="button"
                    @click="openTagsOverlay"
                    aria-label="Show tags filter"
                  >
                    #
                  </button>
                </div>

                <p v-if="tagFilterLoading" class="muted">Filtering by tag…</p>
                <p v-if="tagFilterError" class="error-text">{{ tagFilterError }}</p>

                <div class="list picker-list">
                  <label
                    v-for="block in visibleBlocks"
                    :key="block.id"
                    class="row picker-row"
                    :class="{ disabled: isDisabled(block.id) }"
                    style="gap: 10px; align-items: center"
                  >
                    <input
                      v-if="selectionMode !== 'single'"
                      type="checkbox"
                      :disabled="isDisabled(block.id)"
                      :checked="selectedLocal.includes(block.id)"
                      @change="toggle(block.id)"
                      aria-label="Select block"
                    />
                    <input
                      v-else
                      type="radio"
                      name="kb-select"
                      :disabled="isDisabled(block.id)"
                      :checked="selectedLocal.includes(block.id)"
                      @change="selectSingle(block.id)"
                      aria-label="Select block"
                    />
                    <div style="flex: 1; min-width: 0">
                      <div style="font-weight: 600">{{ block.name }}</div>
                      <div class="muted" style="font-size: 0.9rem">
                        {{ block.type || 'Block' }} · {{ block.token_count ?? 0 }} tokens
                      </div>
                    </div>
                    <ImageThumbnail :image="block.image" :label="block.name" :size="40" :hideWithoutImage="true" />
                    <span v-if="versionBadgeText(block.version)" class="badge">{{ versionBadgeText(block.version) }}</span>
                  </label>
                </div>

                <p v-if="!visibleBlocks.length" class="muted">No blocks found.</p>
              </main>
            </div>

            <transition name="fade">
              <div v-if="isMobile && tagsOverlayOpen" class="panel-backdrop" @click="closeTagsOverlay"></div>
            </transition>

            <aside v-if="isMobile && tagsOverlayOpen" class="sidebar overlay align-left picker-tags-overlay">
              <div class="panel-header" style="justify-content: space-between; margin-bottom: 6px">
                <strong>Tags</strong>
                <div style="display: inline-flex; align-items: center; gap: 8px">
                  <button type="button" class="link" :disabled="!hasActiveTagFilter" @click="clearTag">
                    Clear
                  </button>
                  <button class="panel-toggle" type="button" @click="closeTagsOverlay" aria-label="Hide tags filter">
                    <SvgIcon name="chevron-left" />
                  </button>
                </div>
              </div>

              <p v-if="tagsLoading" class="muted">Loading…</p>
              <p v-else-if="tagsError" class="error-text">{{ tagsError }}</p>
              <KnowledgeTagsTree
                v-else
                :tags="tags"
                :selectedId="selectedTagId"
                :showNoTagsOption="true"
                :noTagsSelected="selectedNoTags"
                noTagsLabel="No tags"
                storageKey="ic.knowledge_tags.tree.open_state.v1"
                :defaultExpandDepth="2"
                @select="selectTag"
                @select-no-tags="selectNoTags"
              />

              <p v-if="!tagsLoading && !tagsError && !tags.length" class="muted">No tags.</p>
            </aside>
          </div>
        </div>

        <div class="modal-actions picker-actions">
          <button
            v-if="selectionMode !== 'single'"
            class="primary"
            type="button"
            :disabled="!selectedLocal.length"
            @click="confirm"
          >
            {{ confirmLabelWithCount }}
          </button>
          <button type="button" @click="close">Cancel</button>
          <div class="spacer"></div>
          <button
            v-if="selectionMode !== 'single' && selectedLocal.length"
            type="button"
            @click="emit('update:selected', [])"
          >
            Clear selection
          </button>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { Teleport } from 'vue';
import { jsonApiList, relationshipId, toIntId, type JsonApiResource } from '@/api/jsonApi';
import ImageThumbnail from '@/components/ImageThumbnail.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import KnowledgeTagsTree, { type KnowledgeTagTreeItem } from '@/components/KnowledgeTagsTree.vue';
import type { KnowledgeBlock } from '@/types/api';

type KnowledgeTagRow = KnowledgeTagTreeItem;

const props = withDefaults(
  defineProps<{
    open: boolean;
    title?: string;
    blocks: KnowledgeBlock[];
    selected: number[];
    disabledBlockIds?: number[];
    confirmLabel?: string;
    selectionMode?: 'multi' | 'single';
  }>(),
  {
    title: 'Select blocks',
    disabledBlockIds: () => [],
    confirmLabel: 'Add selected',
    selectionMode: 'multi',
  }
);

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'update:selected', value: number[]): void;
  (e: 'confirm', value: number[]): void;
}>();

const query = ref('');
const selectedTagId = ref<number | null>(null);
const selectedNoTags = ref(false);

const tagsLoading = ref(false);
const tagsError = ref<string | null>(null);
const tagsLoaded = ref(false);
const tags = ref<KnowledgeTagRow[]>([]);

const tagFilterLoading = ref(false);
const tagFilterError = ref<string | null>(null);
const tagFilteredIds = ref<Set<number> | null>(null);

const isMobile = ref(false);
const tagsOverlayOpen = ref(false);

const selectedLocal = computed(() => props.selected ?? []);
const selectionMode = computed(() => props.selectionMode ?? 'multi');
const hasActiveTagFilter = computed(() => Boolean(selectedTagId.value) || selectedNoTags.value);

const isDisabled = (id: number) => (props.disabledBlockIds || []).includes(id);

const normalize = (text: string) => text.trim().toLowerCase();

const visibleBlocks = computed(() => {
  const q = normalize(query.value);
  const byTag = tagFilteredIds.value;
  const blocks = props.blocks || [];
  return blocks.filter((b) => {
    if (byTag && !byTag.has(b.id)) return false;
    if (!q) return true;
    return normalize(`${b.name} ${b.type || ''}`).includes(q);
  });
});

const confirmLabelWithCount = computed(() => {
  const base = props.confirmLabel ?? 'Add selected';
  if (!selectedLocal.value.length) return base;
  return `${base} (${selectedLocal.value.length})`;
});

const versionBadgeText = (value: unknown) => {
  if (value == null) return '';
  const text = String(value).trim();
  if (!text) return '';
  if (/^v\\d+/i.test(text)) return text;
  if (/^\\d+$/.test(text)) return `v${text}`;
  return text;
};

const close = () => emit('update:open', false);

const confirm = () => {
  if (!selectedLocal.value.length) return;
  emit('confirm', selectedLocal.value);
  close();
};

const toggle = (id: number) => {
  if (isDisabled(id)) return;
  const set = new Set(selectedLocal.value);
  if (set.has(id)) set.delete(id);
  else set.add(id);
  emit('update:selected', Array.from(set));
};

const selectSingle = (id: number) => {
  if (isDisabled(id)) return;
  emit('update:selected', [id]);
  emit('confirm', [id]);
  close();
};

function parseTagRow(resource: JsonApiResource): KnowledgeTagRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const parentId =
    (typeof attrs.parent_id === 'number' ? attrs.parent_id : toIntId(attrs.parent_id as any)) ??
    relationshipId(resource, 'parent');

  return {
    id,
    name: String(attrs.name || '').trim(),
    full_name: String(attrs.full_name || '').trim(),
    parent_id: parentId ?? null,
  };
}

async function loadTags() {
  if (tagsLoading.value || tagsLoaded.value) return;
  tagsLoading.value = true;
  tagsError.value = null;

  try {
    const params = new URLSearchParams();
    params.set('sort', 'full_name');
    const payload = await jsonApiList('/api/ash/knowledge-tags', params);
    tags.value = (payload.data || []).map(parseTagRow).filter((t): t is KnowledgeTagRow => Boolean(t));
    tagsLoaded.value = true;
  } catch (e) {
    console.error(e);
    tagsError.value = e instanceof Error ? e.message : 'Failed to load tags.';
  } finally {
    tagsLoading.value = false;
  }
}

let lastTagFilterRequestId = 0;

async function loadTagFilter(tagId: number | null, noTags = false) {
  const requestId = ++lastTagFilterRequestId;

  if (!tagId && !noTags) {
    tagFilterError.value = null;
    tagFilterLoading.value = false;
    tagFilteredIds.value = null;
    return;
  }

  tagFilterLoading.value = true;
  tagFilterError.value = null;
  tagFilteredIds.value = new Set();

  try {
    const params = new URLSearchParams();
    params.set('sort', 'name');
    if (noTags) params.set('no_tags', 'true');
    else params.set('tag_id', String(tagId));
    params.set('fields[knowledge-blocks]', 'name,image');
    const payload = await jsonApiList('/api/ash/knowledge-blocks', params);
    if (requestId !== lastTagFilterRequestId) return;

    tagFilteredIds.value = new Set(
      (payload.data || [])
        .map((resource) => toIntId(resource.id))
        .filter((id): id is number => typeof id === 'number')
    );
  } catch (e) {
    console.error(e);
    if (requestId !== lastTagFilterRequestId) return;
    tagFilterError.value = e instanceof Error ? e.message : 'Failed to filter blocks.';
    tagFilteredIds.value = null;
  } finally {
    if (requestId === lastTagFilterRequestId) {
      tagFilterLoading.value = false;
    }
  }
}

function updateIsMobile() {
  isMobile.value = window.matchMedia('(max-width: 860px)').matches;
}

function openTagsOverlay() {
  tagsOverlayOpen.value = true;
}

function closeTagsOverlay() {
  tagsOverlayOpen.value = false;
}

function selectTag(id: number) {
  const alreadySelected = !selectedNoTags.value && selectedTagId.value === id;
  selectedNoTags.value = false;
  selectedTagId.value = alreadySelected ? null : id;
  if (isMobile.value) closeTagsOverlay();
}

function selectNoTags() {
  const next = !selectedNoTags.value;
  selectedTagId.value = null;
  selectedNoTags.value = next;
  if (isMobile.value) closeTagsOverlay();
}

function clearTag() {
  selectedTagId.value = null;
  selectedNoTags.value = false;
  if (isMobile.value) closeTagsOverlay();
}

watch(
  () => props.open,
  (open) => {
    if (!open) {
      closeTagsOverlay();
      return;
    }
    void loadTags();
    void loadTagFilter(selectedTagId.value, selectedNoTags.value);
  }
);

watch(
  () => [selectedTagId.value, selectedNoTags.value] as const,
  ([tagId, noTags]) => {
    if (!props.open) return;
    void loadTagFilter(tagId, noTags);
  }
);

watch(
  () => isMobile.value,
  (mobile) => {
    if (!mobile) closeTagsOverlay();
  }
);

onMounted(() => {
  updateIsMobile();
  window.addEventListener('resize', updateIsMobile);
});

onBeforeUnmount(() => {
  window.removeEventListener('resize', updateIsMobile);
});
</script>

<style scoped>
.knowledge-block-picker {
  width: min(880px, 96vw);
  height: min(90vh, 760px);
  max-height: 90vh;
  overflow: hidden;
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.picker-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
}

.picker-controls {
  display: flex;
  align-items: center;
  gap: 8px;
}

.picker-body {
  flex: 1;
  min-height: 0;
  overflow: hidden;
}

.picker-split-wrapper {
  min-height: 0;
  height: 100%;
}

.picker-split {
  height: 100%;
  min-height: 0;
  align-items: stretch;
}

.picker-split .catalog-split__sidebar {
  height: 100%;
  min-height: 0;
}

.picker-tags-card {
  min-height: 0;
  height: 100%;
  overflow: hidden;
}

.picker-main {
  min-height: 0;
}

.picker-list {
  min-height: 0;
  overflow: auto;
}

.picker-tags-overlay {
  top: calc(env(safe-area-inset-top) + 8px);
  bottom: calc(env(safe-area-inset-bottom) + 8px);
}

.picker-actions {
  margin-top: 0;
}

.picker-row.disabled {
  opacity: 0.6;
}

@media (max-width: 720px) {
  .modal-backdrop {
    padding: 0;
    align-items: stretch;
    justify-content: stretch;
  }

  .knowledge-block-picker {
    width: 100%;
    height: calc(var(--app-vh, 1vh) * 100);
    max-height: calc(var(--app-vh, 1vh) * 100);
    border-radius: 0;
    padding-top: calc(12px + env(safe-area-inset-top));
    padding-right: 12px;
    padding-bottom: calc(12px + env(safe-area-inset-bottom));
    padding-left: 12px;
  }
}
</style>
