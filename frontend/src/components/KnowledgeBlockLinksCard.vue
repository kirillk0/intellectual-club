<template>
  <div class="stack kb-links-card">
    <div v-if="showHeader" class="flex" style="justify-content: space-between; align-items: center">
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
      <div
        class="row kb-link-row"
        :class="{ 'kb-link-row--with-controls': showToggle || showActions }"
        v-for="(item, idx) in sortedItems"
        :key="itemKey(item, idx)"
      >
        <div v-if="showToggle || showActions" class="kb-controls">
          <input
            v-if="showToggle"
            class="kb-enabled"
            type="checkbox"
            v-model="item.enabled"
            :disabled="readonly"
            aria-label="Enabled"
            title="Enabled"
            @change="emit('toggle', item)"
          />

          <div v-if="showActions" class="kb-actions" @click.stop>
            <button
              class="kb-action-button"
              type="button"
              :disabled="readonly || idx === 0"
              title="Move up"
              aria-label="Move up"
              @click="emit('move', item, -1)"
            >
              <SvgIcon name="arrow-up" size="15" />
            </button>
            <button
              class="kb-action-button"
              type="button"
              :disabled="readonly || idx === sortedItems.length - 1"
              title="Move down"
              aria-label="Move down"
              @click="emit('move', item, 1)"
            >
              <SvgIcon name="arrow-down" size="15" />
            </button>
            <button
              class="kb-action-button"
              type="button"
              :disabled="readonly"
              title="Delete"
              aria-label="Delete"
              @click="emit('remove', item.id)"
            >
              <SvgIcon name="delete" size="15" />
            </button>
          </div>
        </div>

        <div class="kb-content-row">
          <div
            :class="['kb-body', openable && 'kb-body--openable']"
            :role="openable ? 'button' : undefined"
            :tabindex="openable ? 0 : undefined"
            @click="handleOpen(item.block)"
            @keydown.enter.prevent="handleOpen(item.block)"
            @keydown.space.prevent="handleOpen(item.block)"
          >
            <div class="kb-title">{{ blockName(item.block) }}</div>
          </div>

          <ImageThumbnail
            class="kb-thumbnail"
            :image="blockImage?.(item.block)"
            :label="blockName(item.block)"
            :size="40"
            :hideWithoutImage="true"
          />
        </div>

        <slot name="item-secondary-actions" :item="item"></slot>
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
import SvgIcon from '@/components/icons/SvgIcon.vue';
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
    showHeader?: boolean;
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
    showToggle?: boolean;
    showActions?: boolean;
    itemKey?: (item: LinkItem, index: number) => string | number;
  }>(),
  {
    showHeader: true,
    emptyText: 'No blocks linked yet.',
    addLabel: 'Add',
    addDisabled: false,
    newLabel: 'New',
    newDisabled: false,
    openable: false,
    readonly: false,
    showToggle: true,
    showActions: true,
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

const itemKey = (item: LinkItem, index: number) => props.itemKey?.(item, index) ?? item.id;

const handleOpen = (blockId: number) => {
  if (!props.openable) return;
  emit('open', blockId);
};
</script>

<style scoped>
.kb-links-card {
  container-type: inline-size;
}

.kb-link-row {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  align-items: stretch;
  gap: 8px;
  padding: 10px;
}

.kb-controls {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  min-width: 0;
}

.kb-enabled {
  flex: 0 0 auto;
  width: 18px;
  height: 18px;
  margin: 0;
}

.kb-content-row {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  min-width: 0;
}

.kb-body {
  flex: 1 1 auto;
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

.kb-title {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.kb-actions {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 6px;
  min-width: 0;
}

.kb-action-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 28px;
  height: 28px;
  padding: 0;
  flex: 0 0 28px;
  line-height: 1;
}

.kb-links-move {
  transition: transform 160ms ease;
  will-change: transform;
}

@container (min-width: 560px) {
  .kb-link-row--with-controls {
    grid-template-columns: auto minmax(0, 1fr) auto auto;
    align-items: center;
  }

  .kb-link-row--with-controls .kb-controls {
    display: contents;
  }

  .kb-link-row--with-controls .kb-enabled {
    grid-column: 1;
    grid-row: 1;
    align-self: center;
  }

  .kb-link-row--with-controls .kb-content-row {
    grid-column: 2;
    grid-row: 1;
    align-items: center;
  }

  .kb-link-row--with-controls .kb-actions {
    grid-column: 3;
    grid-row: 1;
    align-self: center;
  }

  .kb-link-row--with-controls :slotted(*) {
    grid-column: 4;
    grid-row: 1;
    align-self: center;
  }
}
</style>
