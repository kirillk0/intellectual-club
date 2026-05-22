<template>
  <component
    :is="as"
    class="row tool-binding-list-item"
    :class="{
      'tool-binding-list-item--shadowed': shadowed,
      'tool-binding-list-item--with-controls': hasControls,
    }"
  >
    <div v-if="hasControls" class="tool-binding-list-item__controls">
      <slot name="leading"></slot>
      <div v-if="slots.actions" class="tool-binding-list-item__actions" @click.stop>
        <slot name="actions"></slot>
      </div>
    </div>

    <div
      :class="['tool-binding-list-item__body', openable && 'tool-binding-list-item__body--openable']"
      :role="openable ? 'button' : undefined"
      :tabindex="openable ? 0 : undefined"
      @click="emitOpen"
      @keydown.enter.prevent="emitOpen"
      @keydown.space.prevent="emitOpen"
    >
      <div class="tool-binding-list-item__body-main">
        <div class="tool-binding-list-item__title-line">
          <span
            v-if="isOutlet"
            class="status-dot"
            :class="isOnline ? 'success' : 'danger'"
            :title="isOnline ? 'Online' : 'Offline'"
          />
          <span class="tool-binding-list-item__title" :title="titleText">
            <span class="tool-binding-list-item__primary">
              <span class="tool-binding-list-item__name">{{ name }}</span>
              <span v-if="alias" class="muted tool-binding-list-item__alias">({{ alias }})</span>
            </span>
            <span v-if="typeTitle || type" class="tool-binding-list-item__type">
              <span class="tool-binding-list-item__separator">-</span>
              <ToolTypeBadge :type="type" :typeTitle="typeTitle" />
            </span>
          </span>
          <span v-if="shadowed" class="badge tool-binding-list-item__shadowed" :title="shadowedReason">
            Shadowed
          </span>
        </div>
        <slot name="meta"></slot>
        <slot name="footer"></slot>
      </div>
    </div>

    <div v-if="slots.secondary" class="tool-binding-list-item__secondary">
      <slot name="secondary"></slot>
    </div>
  </component>
</template>

<script setup lang="ts">
import { computed, useSlots } from 'vue';
import ToolTypeBadge from '@/components/ToolTypeBadge.vue';

const props = withDefaults(
  defineProps<{
    name: string;
    alias?: string;
    type?: string | null;
    typeTitle?: string | null;
    isOutlet?: boolean;
    isOnline?: boolean;
    openable?: boolean;
    shadowed?: boolean;
    shadowedReason?: string;
    as?: 'div' | 'label';
  }>(),
  {
    alias: '',
    type: '',
    typeTitle: '',
    isOutlet: false,
    isOnline: false,
    openable: false,
    shadowed: false,
    shadowedReason: 'Another enabled tool with this alias has priority.',
    as: 'div',
  }
);

const emit = defineEmits<{
  (e: 'open'): void;
}>();

const slots = useSlots();
const hasControls = computed(() => Boolean(slots.leading || slots.actions));
const titleText = computed(() => {
  const type = props.typeTitle || props.type || '';
  const primary = props.alias ? `${props.name} (${props.alias})` : props.name;
  return type ? `${primary} - ${type}` : primary;
});

const emitOpen = () => {
  if (!props.openable) return;
  emit('open');
};
</script>

<style scoped>
.tool-binding-list-item {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  align-items: stretch;
  gap: 8px;
  padding: 10px;
}

.tool-binding-list-item__controls {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  min-width: 0;
}

.tool-binding-list-item__body,
.tool-binding-list-item__body-main {
  min-width: 0;
}

.tool-binding-list-item__body--openable {
  cursor: pointer;
}

.tool-binding-list-item__body--openable:hover .tool-binding-list-item__name {
  text-decoration: underline;
}

.tool-binding-list-item__body--openable:focus-visible {
  outline: 2px solid #4c8dff;
  outline-offset: 2px;
  border-radius: 6px;
}

.tool-binding-list-item__title-line {
  display: flex;
  align-items: flex-start;
  gap: 6px;
  min-width: 0;
}

.tool-binding-list-item__title {
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
  font-weight: 700;
}

.tool-binding-list-item__primary {
  display: flex;
  gap: 4px;
}

.tool-binding-list-item__primary,
.tool-binding-list-item__name,
.tool-binding-list-item__alias,
.tool-binding-list-item__type {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.tool-binding-list-item__name {
  font-weight: 700;
}

.tool-binding-list-item__alias {
  font-weight: 500;
}

.tool-binding-list-item__type {
  font-size: 0.85rem;
  font-weight: 400;
}

.tool-binding-list-item__separator {
  display: none;
  margin: 0 4px;
}

.tool-binding-list-item__shadowed {
  flex: 0 0 auto;
  font-size: 0.72rem;
}

.tool-binding-list-item--shadowed {
  opacity: 0.68;
}

.tool-binding-list-item__actions {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 6px;
  min-width: 0;
}

@container (min-width: 560px) {
  .tool-binding-list-item--with-controls {
    grid-template-columns: auto minmax(0, 1fr) auto auto;
    align-items: center;
  }

  .tool-binding-list-item--with-controls .tool-binding-list-item__controls {
    display: contents;
  }

  .tool-binding-list-item--with-controls .tool-binding-list-item__controls :slotted(:first-child) {
    grid-column: 1;
    grid-row: 1;
    align-self: center;
  }

  .tool-binding-list-item--with-controls .tool-binding-list-item__body {
    grid-column: 2;
    grid-row: 1;
  }

  .tool-binding-list-item--with-controls .tool-binding-list-item__title-line {
    align-items: center;
  }

  .tool-binding-list-item--with-controls .tool-binding-list-item__title {
    flex-direction: row;
    gap: 0;
  }

  .tool-binding-list-item--with-controls .tool-binding-list-item__type {
    font-size: inherit;
  }

  .tool-binding-list-item--with-controls .tool-binding-list-item__separator {
    display: inline;
  }

  .tool-binding-list-item--with-controls .tool-binding-list-item__actions {
    grid-column: 3;
    grid-row: 1;
    align-self: center;
  }

  .tool-binding-list-item--with-controls .tool-binding-list-item__secondary {
    grid-column: 4;
    grid-row: 1;
    align-self: center;
  }
}
</style>
