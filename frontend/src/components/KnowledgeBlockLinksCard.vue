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
      <KnowledgeBlockListItem
        v-for="(item, idx) in sortedItems"
        :key="itemKey(item, idx)"
        :name="blockName(item.block)"
        :image="blockImage?.(item.block)"
        :meta="blockMeta(item)"
        :version="blockVersionText(item)"
        :tokenCount="blockTokenCountValue(item)"
        :openable="openable"
        @open="handleOpen(item.block)"
      >
        <template v-if="showToggle" #leading>
          <input
            class="kb-enabled"
            type="checkbox"
            :checked="item.enabled"
            :disabled="readonly"
            aria-label="Enabled"
            title="Enabled"
            @change="handleToggle(item, $event)"
          />
        </template>

        <template v-if="showActions" #actions>
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
        </template>

        <template v-if="slots['item-secondary-actions']" #secondary>
          <slot name="item-secondary-actions" :item="item"></slot>
        </template>
      </KnowledgeBlockListItem>
    </TransitionGroup>
    <div v-else class="list">
      <p class="muted">{{ emptyText }}</p>
    </div>
  </div>
</template>

<script setup lang="ts" generic="T extends { id: number; block: number; enabled: boolean; sequence: number }">
import { computed, useSlots } from 'vue';
import KnowledgeBlockListItem from '@/components/KnowledgeBlockListItem.vue';
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
    items: T[];
    blockName: (blockId: number) => string;
    blockImage?: (blockId: number) => ImageAsset | null;
    blockVersion?: (blockId: number) => string | undefined;
    blockTokenCount?: (blockId: number, item: T) => number | string | null | undefined;
    metaText?: (item: T) => string;
    emptyText?: string;
    addLabel?: string;
    addDisabled?: boolean;
    newLabel?: string;
    newDisabled?: boolean;
    openable?: boolean;
    readonly?: boolean;
    showToggle?: boolean;
    showActions?: boolean;
    itemKey?: (item: T, index: number) => string | number;
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
  (e: 'move', item: T, delta: number): void;
  (e: 'remove', id: number): void;
  (e: 'toggle', item: T, enabled: boolean): void;
}>();

const sortedItems = computed<T[]>(() => [...(props.items || [])].sort((a, b) => a.sequence - b.sequence));
const slots = useSlots();

const itemKey = (item: T, index: number) => props.itemKey?.(item, index) ?? item.id;
const blockMeta = (item: T) => props.metaText?.(item) || '';
const blockVersionText = (item: T) => props.blockVersion?.(item.block) || '';
const blockTokenCountValue = (item: T) => props.blockTokenCount?.(item.block, item) ?? null;

const handleOpen = (blockId: number) => {
  if (!props.openable) return;
  emit('open', blockId);
};

const handleToggle = (item: T, event: Event) => {
  const enabled = (event.target as HTMLInputElement | null)?.checked === true;
  emit('toggle', item, enabled);
};
</script>

<style scoped>
.kb-links-card {
  container-type: inline-size;
}

.kb-enabled {
  flex: 0 0 auto;
  width: 18px;
  height: 18px;
  margin: 0;
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
</style>
