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
      <div
        v-for="(item, idx) in sortedItems"
        :key="itemKey(item)"
        class="row tool-binding-row"
        :class="{
          'tool-binding-row--shadowed': isShadowed(item),
          'tool-binding-row--with-controls': showToggle || showActions,
        }"
      >
        <div v-if="showToggle || showActions" class="tool-binding-controls">
          <input
            v-if="showToggle"
            class="tool-binding-enabled"
            type="checkbox"
            :checked="item.enabled"
            :disabled="readonly || toggleDisabled(item)"
            :aria-label="toggleLabel"
            :title="toggleLabel"
            @change="handleToggle(item, $event)"
          />

          <div v-if="showActions" class="tool-binding-actions" @click.stop>
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
          </div>
        </div>

        <div class="tool-binding-body">
          <div class="tool-binding-title-line">
            <span
              v-if="toolIsOutlet?.(item)"
              class="status-dot"
              :class="toolIsOnline?.(item) ? 'success' : 'danger'"
              :title="toolIsOnline?.(item) ? 'Online' : 'Offline'"
            />
            <span class="tool-binding-title" :title="toolText(item)">
              <span class="tool-binding-title__primary">
                <span class="tool-binding-title__name">{{ toolNameText(item) }}</span>
                <span v-if="toolAliasText(item)" class="muted tool-binding-title__alias">
                  ({{ toolAliasText(item) }})
                </span>
              </span>
              <span v-if="toolTypeText(item)" class="tool-binding-title__type">
                <span class="tool-binding-title__separator">-</span>{{ toolTypeText(item) }}
              </span>
            </span>
            <span v-if="isShadowed(item)" class="badge tool-binding-shadowed" :title="shadowedReason(item)">
              Shadowed
            </span>
          </div>
          <slot name="item-meta-extra" :item="item"></slot>
          <slot name="item-footer" :item="item"></slot>
        </div>

        <slot name="item-secondary-actions" :item="item" :index="idx"></slot>
      </div>
    </TransitionGroup>
    <div v-else class="list">
      <p class="muted">{{ emptyText }}</p>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, useSlots } from 'vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';

type ToolBindingItem = {
  id: number;
  alias: string;
  enabled: boolean;
  sequence: number;
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
    items: ToolBindingItem[];
    toolLabel: (item: ToolBindingItem) => string;
    toolText?: (item: ToolBindingItem) => string;
    toolIsOutlet?: (item: ToolBindingItem) => boolean;
    toolIsOnline?: (item: ToolBindingItem) => boolean;
    emptyText?: string;
    toggleLabel?: string;
    readonly?: boolean;
    showToggle?: boolean;
    showActions?: boolean;
    addLabel?: string;
    addDisabled?: boolean;
    toggleDisabled?: (item: ToolBindingItem) => boolean;
    actionsDisabled?: (item: ToolBindingItem) => boolean;
  }>(),
  {
    title: '',
    showHeader: true,
    emptyText: 'No tools attached.',
    toggleLabel: 'enabled',
    readonly: false,
    showToggle: true,
    showActions: true,
    addLabel: 'Add',
    addDisabled: false,
    toggleDisabled: () => false,
    actionsDisabled: () => false,
  }
);

const emit = defineEmits<{
  (e: 'add'): void;
  (e: 'move', item: ToolBindingItem, delta: number): void;
  (e: 'remove', id: number): void;
  (e: 'toggle', item: ToolBindingItem, enabled: boolean): void;
}>();

const slots = useSlots();

const sortedItems = computed(() => [...(props.items || [])].sort((a, b) => a.sequence - b.sequence || a.id - b.id));

const handleToggle = (item: ToolBindingItem, event: Event) => {
  const target = event.target as HTMLInputElement | null;
  emit('toggle', item, Boolean(target?.checked));
};

const toggleDisabled = (item: ToolBindingItem) => props.toggleDisabled?.(item) ?? false;
const actionsDisabled = (item: ToolBindingItem) => props.actionsDisabled?.(item) ?? false;
const isShadowed = (item: ToolBindingItem) => item.shadowed === true;
const itemKey = (item: ToolBindingItem) => `${item.source || 'binding'}:${item.id}`;
const toolText = (item: ToolBindingItem) => {
  const explicit = props.toolText?.(item);
  if (explicit) return explicit;

  const label = props.toolLabel(item);
  const match = label.match(/^(.*)\s+\(([^()]*)\)$/);
  if (!match) return item.alias ? `${label} (${item.alias})` : label;

  const [, name, type] = match;
  return item.alias ? `${name} (${item.alias}) - ${type}` : `${name} - ${type}`;
};
const toolTextParts = (item: ToolBindingItem) => {
  const text = toolText(item);
  const separatorIndex = text.lastIndexOf(' - ');
  const primary = separatorIndex < 0 ? text : text.slice(0, separatorIndex);
  const type = separatorIndex < 0 ? '' : text.slice(separatorIndex + 3);
  const aliasMatch = primary.match(/^(.*)\s+\(([^()]*)\)$/);

  return aliasMatch
    ? { name: aliasMatch[1], alias: aliasMatch[2], type }
    : { name: primary, alias: '', type };
};
const toolNameText = (item: ToolBindingItem) => toolTextParts(item).name;
const toolAliasText = (item: ToolBindingItem) => toolTextParts(item).alias;
const toolTypeText = (item: ToolBindingItem) => toolTextParts(item).type;
const shadowedReason = (item: ToolBindingItem) =>
  typeof item.shadowedReason === 'string' && item.shadowedReason.trim()
    ? item.shadowedReason
    : 'Another enabled tool with this alias has priority.';
</script>

<style scoped>
.tool-bindings-card {
  container-type: inline-size;
}

.tool-binding-row {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  align-items: stretch;
  gap: 8px;
  padding: 10px;
}

.tool-binding-controls {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  min-width: 0;
}

.tool-binding-enabled {
  flex: 0 0 auto;
  width: 18px;
  height: 18px;
  margin: 0;
}

.tool-binding-body {
  min-width: 0;
}

.tool-binding-title-line {
  display: flex;
  align-items: flex-start;
  gap: 6px;
  min-width: 0;
}

.tool-binding-title {
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
  font-weight: 700;
}

.tool-binding-title__primary {
  display: flex;
  gap: 4px;
}

.tool-binding-title__primary,
.tool-binding-title__name,
.tool-binding-title__alias,
.tool-binding-title__type {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.tool-binding-title__name {
  font-weight: 700;
}

.tool-binding-title__alias {
  font-weight: 500;
}

.tool-binding-title__type {
  font-size: 0.85rem;
  font-weight: 400;
}

.tool-binding-title__separator {
  display: none;
  margin: 0 4px;
}

.tool-binding-shadowed {
  flex: 0 0 auto;
  font-size: 0.72rem;
}

.tool-binding-row--shadowed {
  opacity: 0.68;
}

.tool-binding-actions {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 6px;
  min-width: 0;
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

@container (min-width: 560px) {
  .tool-binding-row--with-controls {
    grid-template-columns: auto minmax(0, 1fr) auto auto;
    align-items: center;
  }

  .tool-binding-row--with-controls .tool-binding-controls {
    display: contents;
  }

  .tool-binding-row--with-controls .tool-binding-enabled {
    grid-column: 1;
    grid-row: 1;
    align-self: center;
  }

  .tool-binding-row--with-controls .tool-binding-body {
    grid-column: 2;
    grid-row: 1;
  }

  .tool-binding-row--with-controls .tool-binding-title-line {
    align-items: center;
  }

  .tool-binding-row--with-controls .tool-binding-title {
    flex-direction: row;
    gap: 0;
  }

  .tool-binding-row--with-controls .tool-binding-title__type {
    font-size: inherit;
    font-weight: 400;
  }

  .tool-binding-row--with-controls .tool-binding-title__separator {
    display: inline;
  }

  .tool-binding-row--with-controls .tool-binding-actions {
    grid-column: 3;
    grid-row: 1;
    align-self: center;
  }

  .tool-binding-row--with-controls :slotted(*) {
    grid-column: 4;
    grid-row: 1;
    align-self: center;
  }
}
</style>
