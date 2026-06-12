<template>
  <div class="stack tool-bindings-card">
    <div v-if="showHeader && title" class="flex" style="justify-content: space-between; align-items: center">
      <strong v-if="title">{{ title }}</strong>
      <div v-if="slots['header-actions']" class="flex" style="gap: 8px; align-items: center">
        <slot name="header-actions"></slot>
      </div>
      <div v-else class="flex" style="gap: 8px; align-items: center">
        <button type="button" :disabled="addDisabled || readonly" @click="emit('add')">
          {{ addLabel }}
        </button>
      </div>
    </div>

    <slot name="note"></slot>

    <TransitionGroup v-if="sortedItems.length" name="tool-bindings" tag="div" class="list">
      <ToolBindingListItem
        v-for="(item, idx) in sortedItems"
        :key="itemKey(item)"
        :name="toolNameText(item)"
        :alias="toolAliasText(item)"
        :type="toolTypeValue(item)"
        :typeTitle="toolTypeText(item)"
        :isOutlet="toolIsOutlet?.(item)"
        :isOnline="toolIsOnline?.(item)"
        :shadowed="isShadowed(item)"
        :shadowedReason="shadowedReason(item)"
        :openable="openable"
        @open="handleOpen(item)"
      >
        <template v-if="showToggle" #leading>
          <input
            class="tool-binding-enabled"
            type="checkbox"
            :checked="item.enabled"
            :disabled="readonly || toggleDisabled(item)"
            :aria-label="toggleLabel"
            :title="toggleLabel"
            @change="handleToggle(item, $event)"
          />
        </template>

        <template v-if="showActions" #actions>
          <button
            class="tool-binding-action-button"
            type="button"
            :disabled="readonly || actionsDisabled(item) || idx === 0"
            title="Move up"
            aria-label="Move up"
            @click="emit('move', item, -1)"
          >
            <SvgIcon name="arrow-up" size="15" />
          </button>
          <button
            class="tool-binding-action-button"
            type="button"
            :disabled="readonly || actionsDisabled(item) || idx === sortedItems.length - 1"
            title="Move down"
            aria-label="Move down"
            @click="emit('move', item, 1)"
          >
            <SvgIcon name="arrow-down" size="15" />
          </button>
          <button
            class="tool-binding-action-button danger"
            type="button"
            :disabled="readonly || actionsDisabled(item)"
            title="Delete"
            aria-label="Delete"
            @click="emit('remove', item.id)"
          >
            <SvgIcon name="delete" size="15" />
          </button>
        </template>

        <template v-if="slots['item-meta-extra']" #meta>
          <slot name="item-meta-extra" :item="item"></slot>
        </template>

        <template v-if="slots['item-footer']" #footer>
          <slot name="item-footer" :item="item"></slot>
        </template>

        <template v-if="slots['item-secondary-actions']" #secondary>
          <slot name="item-secondary-actions" :item="item" :index="idx"></slot>
        </template>
      </ToolBindingListItem>
    </TransitionGroup>
    <div v-else class="list">
      <p class="muted">{{ emptyText }}</p>
    </div>
  </div>
</template>

<script setup lang="ts" generic="T extends { id: number; alias: string; enabled: boolean; sequence?: number; tool_instance_id?: number | null; shadowed?: boolean; shadowedReason?: string; source?: string }">
import { computed, useSlots } from 'vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import ToolBindingListItem from '@/components/ToolBindingListItem.vue';

type ToolBindingItem = {
  id: number;
  alias: string;
  enabled: boolean;
  sequence?: number;
  tool_instance_id?: number | null;
  shadowed?: boolean;
  shadowedReason?: string;
  source?: string;
  [key: string]: unknown;
};

const props = withDefaults(
  defineProps<{
    title?: string;
    showHeader?: boolean;
    items: T[];
    toolLabel: (item: T) => string;
    toolText?: (item: T) => string;
    toolType?: (item: T) => string | null | undefined;
    toolIsOutlet?: (item: T) => boolean;
    toolIsOnline?: (item: T) => boolean;
    emptyText?: string;
    toggleLabel?: string;
    readonly?: boolean;
    showToggle?: boolean;
    showActions?: boolean;
    openable?: boolean;
    addLabel?: string;
    addDisabled?: boolean;
    toggleDisabled?: (item: T) => boolean;
    actionsDisabled?: (item: T) => boolean;
  }>(),
  {
    title: '',
    showHeader: true,
    emptyText: 'No tools attached.',
    toggleLabel: 'enabled',
    readonly: false,
    showToggle: true,
    showActions: true,
    openable: false,
    addLabel: 'Add',
    addDisabled: false,
    toggleDisabled: () => false,
    actionsDisabled: () => false,
  }
);

const emit = defineEmits<{
  (e: 'add'): void;
  (e: 'move', item: T, delta: number): void;
  (e: 'remove', id: number): void;
  (e: 'toggle', item: T, enabled: boolean): void;
  (e: 'open', toolInstanceId: number): void;
}>();

const slots = useSlots();

const sortedItems = computed<T[]>(() =>
  [...(props.items || [])].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0) || a.id - b.id)
);

const handleToggle = (item: T, event: Event) => {
  const target = event.target as HTMLInputElement | null;
  emit('toggle', item, Boolean(target?.checked));
};
const handleOpen = (item: T) => {
  if (!props.openable) return;
  const toolInstanceId = Number(item.tool_instance_id || 0);
  if (!toolInstanceId) return;
  emit('open', toolInstanceId);
};

const toggleDisabled = (item: T) => props.toggleDisabled?.(item) ?? false;
const actionsDisabled = (item: T) => props.actionsDisabled?.(item) ?? false;
const isShadowed = (item: T) => item.shadowed === true;
const itemKey = (item: T) => `${item.source || 'binding'}:${item.id}`;
const toolText = (item: T) => {
  const explicit = props.toolText?.(item);
  if (explicit) return explicit;

  const label = props.toolLabel(item);
  const match = label.match(/^(.*)\s+\(([^()]*)\)$/);
  if (!match) return item.alias ? `${label} (${item.alias})` : label;

  const [, name, type] = match;
  return item.alias ? `${name} (${item.alias}) - ${type}` : `${name} - ${type}`;
};
const toolTextParts = (item: T) => {
  const text = toolText(item);
  const separatorIndex = text.lastIndexOf(' - ');
  const primary = separatorIndex < 0 ? text : text.slice(0, separatorIndex);
  const type = separatorIndex < 0 ? '' : text.slice(separatorIndex + 3);
  const aliasMatch = primary.match(/^(.*)\s+\(([^()]*)\)$/);

  return aliasMatch
    ? { name: aliasMatch[1], alias: aliasMatch[2], type }
    : { name: primary, alias: '', type };
};
const toolNameText = (item: T) => toolTextParts(item).name;
const toolAliasText = (item: T) => toolTextParts(item).alias;
const toolTypeText = (item: T) => toolTextParts(item).type;
const toolTypeValue = (item: T) => props.toolType?.(item) || toolTypeText(item);
const shadowedReason = (item: T) =>
  typeof item.shadowedReason === 'string' && item.shadowedReason.trim()
    ? item.shadowedReason
    : 'Another enabled tool with this alias has priority.';
</script>

<style scoped>
.tool-bindings-card {
  container-type: inline-size;
}

.tool-binding-enabled {
  flex: 0 0 auto;
  width: 18px;
  height: 18px;
  margin: 0;
}

.tool-binding-action-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 28px;
  height: 28px;
  padding: 0;
  flex: 0 0 28px;
  line-height: 1;
}

.tool-bindings-move {
  transition: transform 160ms ease;
  will-change: transform;
}
</style>
