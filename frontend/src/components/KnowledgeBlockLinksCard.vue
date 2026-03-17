<template>
  <div class="stack kb-links-card">
    <div class="flex" style="justify-content: space-between; align-items: center">
      <strong>{{ title }}</strong>
      <div class="flex" style="gap: 8px; align-items: center">
        <slot name="header-actions">
          <button type="button" :disabled="addDisabled || readonly" @click="emit('add')">
            {{ addLabel }}
          </button>
          <button type="button" :disabled="newDisabled || readonly" @click="emit('new')">
            {{ newLabel }}
          </button>
        </slot>
      </div>
    </div>

    <slot name="note"></slot>

    <TransitionGroup v-if="sortedItems.length" name="kb-links" tag="div" class="list">
      <div class="row" v-for="(item, idx) in sortedItems" :key="item.id">
        <input
          class="kb-enabled"
          type="checkbox"
          v-model="item.enabled"
          :disabled="readonly"
          aria-label="Enabled"
          title="Enabled"
          @change="emit('toggle', item)"
        />

        <div
          :class="['kb-body', openable && 'kb-body--openable']"
          :role="openable ? 'button' : undefined"
          :tabindex="openable ? 0 : undefined"
          @click="handleOpen(item.block)"
          @keydown.enter.prevent="handleOpen(item.block)"
          @keydown.space.prevent="handleOpen(item.block)"
        >
          <div class="kb-title">{{ blockName(item.block) }}</div>
          <div class="muted kb-meta">{{ metaText ? metaText(item) : defaultMetaText(item) }}</div>
        </div>

        <ImageThumbnail
          class="kb-thumbnail"
          :image="blockImage?.(item.block)"
          :label="blockName(item.block)"
          :size="40"
          :hideWithoutImage="true"
        />

        <slot name="item-secondary-actions" :item="item"></slot>

        <div class="kb-actions" @click.stop>
          <button type="button" :disabled="readonly || idx === 0" @click="emit('move', item, -1)">
            ↑
          </button>
          <button
            type="button"
            :disabled="readonly || idx === sortedItems.length - 1"
            @click="emit('move', item, 1)"
          >
            ↓
          </button>
          <button type="button" :disabled="readonly" @click="emit('remove', item.id)">✕</button>
        </div>
      </div>
    </TransitionGroup>
    <div v-else class="list">
      <p class="muted">{{ emptyText }}</p>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import ImageThumbnail from '@/components/ImageThumbnail.vue';
import type { ImageAsset } from '@/types/api';

type LinkItem = {
  id: number;
  block: number;
  enabled: boolean;
  sequence: number;
};

const props = withDefaults(
  defineProps<{
    title: string;
    items: LinkItem[];
    blockName: (blockId: number) => string;
    blockImage?: (blockId: number) => ImageAsset | null;
    blockVersion?: (blockId: number) => string | undefined;
    metaText?: (item: LinkItem) => string;
    emptyText?: string;
    addLabel?: string;
    addDisabled?: boolean;
    newLabel?: string;
    newDisabled?: boolean;
    openable?: boolean;
    readonly?: boolean;
  }>(),
  {
    emptyText: 'No blocks linked yet.',
    addLabel: 'Add',
    addDisabled: false,
    newLabel: 'New',
    newDisabled: false,
    openable: false,
    readonly: false,
  }
);

const emit = defineEmits<{
  (e: 'add'): void;
  (e: 'new'): void;
  (e: 'open', blockId: number): void;
  (e: 'move', item: LinkItem, delta: number): void;
  (e: 'remove', id: number): void;
  (e: 'toggle', item: LinkItem): void;
}>();

const sortedItems = computed(() => [...(props.items || [])].sort((a, b) => a.sequence - b.sequence));

const defaultMetaText = (item: LinkItem) => {
  const base = `order ${item.sequence}`;
  const version = (props.blockVersion?.(item.block) || '').trim();
  return version ? `${base} · ${version}` : base;
};

const handleOpen = (blockId: number) => {
  if (!props.openable) return;
  emit('open', blockId);
};
</script>

<style scoped>
.row {
  flex-wrap: wrap;
  align-items: flex-start;
}

.kb-enabled {
  margin-top: 2px;
}

.kb-body {
  flex: 1 1 220px;
  min-width: 0;
}

.kb-thumbnail {
  flex: 0 0 auto;
}

.kb-body--openable {
  cursor: pointer;
}

.kb-body--openable:hover .kb-title {
  text-decoration: underline;
}

.kb-body--openable:focus-visible {
  outline: 2px solid #4c8dff;
  outline-offset: 2px;
  border-radius: 6px;
}

.kb-title,
.kb-meta {
  overflow-wrap: anywhere;
  word-break: break-word;
}

.kb-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-left: auto;
}

@media (max-width: 520px) {
  .kb-actions {
    width: 100%;
    justify-content: flex-end;
  }
}

.kb-links-move {
  transition: transform 160ms ease;
  will-change: transform;
}
</style>
