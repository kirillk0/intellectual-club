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
        :class="{ 'tool-binding-row--shadowed': isShadowed(item) }"
      >
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

        <div class="tool-binding-body">
          <div class="tool-binding-title-line">
            <div class="tool-binding-title">
              <span class="muted tool-binding-title__label">Alias:</span>
              {{ item.alias || '—' }}
            </div>
            <span
              v-if="isShadowed(item)"
              class="badge tool-binding-shadowed"
              :title="shadowedReason(item)"
            >
              Shadowed
            </span>
          </div>
          <div class="muted tool-binding-meta" :title="toolLabel(item)">
            <span
              v-if="toolIsOutlet?.(item)"
              class="status-dot"
              :class="toolIsOnline?.(item) ? 'success' : 'danger'"
              :title="toolIsOnline?.(item) ? 'Online' : 'Offline'"
            />
            <span class="tool-binding-meta__text">{{ toolLabel(item) }}</span>
          </div>
          <slot name="item-meta-extra" :item="item"></slot>
          <slot name="item-footer" :item="item"></slot>
        </div>

        <slot name="item-secondary-actions" :item="item" :index="idx"></slot>

        <div v-if="showActions" class="tool-binding-actions" @click.stop>
          <button
            type="button"
            :disabled="readonly || actionsDisabled(item) || idx === 0"
            title="Move up"
            aria-label="Move up"
            @click="emit('move', item, -1)"
          >
            ↑
          </button>
          <button
            type="button"
            :disabled="readonly || actionsDisabled(item) || idx === sortedItems.length - 1"
            title="Move down"
            aria-label="Move down"
            @click="emit('move', item, 1)"
          >
            ↓
          </button>
          <button
            type="button"
            class="danger"
            :disabled="readonly || actionsDisabled(item)"
            title="Delete"
            aria-label="Delete"
            @click="emit('remove', item.id)"
          >
            ✕
          </button>
        </div>
      </div>
    </TransitionGroup>
    <div v-else class="list">
      <p class="muted">{{ emptyText }}</p>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, useSlots } from 'vue';

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
const shadowedReason = (item: ToolBindingItem) =>
  typeof item.shadowedReason === 'string' && item.shadowedReason.trim()
    ? item.shadowedReason
    : 'Another enabled tool with this alias has priority.';
</script>

<style scoped>
.tool-binding-row {
  flex-wrap: wrap;
  align-items: flex-start;
}

.tool-binding-enabled {
  margin-top: 2px;
}

.tool-binding-body {
  flex: 1 1 220px;
  min-width: 0;
}

.tool-binding-title-line {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}

.tool-binding-title {
  font-weight: 700;
  overflow-wrap: anywhere;
  word-break: break-word;
}

.tool-binding-title__label {
  font-weight: 500;
}

.tool-binding-shadowed {
  flex: 0 0 auto;
  font-size: 0.72rem;
}

.tool-binding-row--shadowed {
  opacity: 0.68;
}

.tool-binding-meta {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
  font-size: 0.85rem;
}

.tool-binding-meta__text {
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.tool-binding-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-left: auto;
}

@media (max-width: 520px) {
  .tool-binding-actions {
    width: 100%;
    justify-content: flex-end;
  }
}

.tool-bindings-move {
  transition: transform 160ms ease;
  will-change: transform;
}
</style>
