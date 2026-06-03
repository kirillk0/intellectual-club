<template>
  <component
    :is="as"
    class="row kb-list-item"
    :class="{
      'kb-list-item--with-controls': hasControls,
      disabled,
    }"
  >
    <div v-if="hasControls" class="kb-list-item__controls">
      <slot name="leading"></slot>
      <div v-if="slots.actions" class="kb-list-item__actions" @click.stop>
        <slot name="actions"></slot>
      </div>
    </div>

    <div class="kb-list-item__content-row">
      <div
        :class="['kb-list-item__body', openable && 'kb-list-item__body--openable']"
        :role="openable ? 'button' : undefined"
        :tabindex="openable ? 0 : undefined"
        @click="emitOpen"
        @keydown.enter.prevent="emitOpen"
        @keydown.space.prevent="emitOpen"
      >
        <div class="kb-list-item__title">{{ name }}</div>
        <div v-if="meta" class="muted kb-list-item__meta">{{ meta }}</div>
      </div>

      <ImageThumbnail
        class="kb-list-item__thumbnail"
        :image="image"
        :label="name"
        :size="40"
        :hideWithoutImage="true"
      />
      <span v-if="badgeText" class="badge kb-list-item__badge">{{ badgeText }}</span>
    </div>

    <div v-if="slots.secondary" class="kb-list-item__secondary">
      <slot name="secondary"></slot>
    </div>
  </component>
</template>

<script setup lang="ts">
import { computed, useSlots } from 'vue';
import ImageThumbnail from '@/components/ImageThumbnail.vue';
import type { ImageAsset } from '@/types/api';

const props = withDefaults(
  defineProps<{
    name: string;
    image?: ImageAsset | null;
    meta?: string;
    version?: string | null;
    openable?: boolean;
    disabled?: boolean;
    as?: 'div' | 'label';
  }>(),
  {
    image: null,
    meta: '',
    version: '',
    openable: false,
    disabled: false,
    as: 'div',
  }
);

const emit = defineEmits<{
  (e: 'open'): void;
}>();

const slots = useSlots();
const hasControls = computed(() => Boolean(slots.leading || slots.actions));
const badgeText = computed(() => {
  const text = String(props.version || '').trim();
  if (!text) return '';
  if (/^v\d+/i.test(text)) return text;
  if (/^\d+$/.test(text)) return `v${text}`;
  return text;
});

const emitOpen = () => {
  if (!props.openable) return;
  emit('open');
};
</script>

<style scoped>
.kb-list-item {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  align-items: stretch;
  gap: 8px;
  padding: 10px;
}

.kb-list-item.disabled {
  opacity: 0.6;
}

.kb-list-item__controls {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  min-width: 0;
}

.kb-list-item__content-row {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  min-width: 0;
}

.kb-list-item__body {
  flex: 1 1 auto;
  min-width: 0;
}

.kb-list-item__thumbnail,
.kb-list-item__badge {
  flex: 0 0 auto;
}

.kb-list-item__body--openable {
  cursor: pointer;
}

.kb-list-item__body--openable:hover .kb-list-item__title {
  text-decoration: underline;
}

.kb-list-item__body--openable:focus-visible {
  outline: 2px solid var(--color-focus);
  outline-offset: 2px;
  border-radius: 6px;
}

.kb-list-item__title,
.kb-list-item__meta {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.kb-list-item__title {
  font-weight: 600;
}

.kb-list-item__meta {
  margin-top: 2px;
  font-size: 0.9rem;
}

.kb-list-item__actions {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 6px;
  min-width: 0;
}

@container (min-width: 560px) {
  .kb-list-item--with-controls {
    grid-template-columns: auto minmax(0, 1fr) auto auto;
    align-items: center;
  }

  .kb-list-item--with-controls .kb-list-item__controls {
    display: contents;
  }

  .kb-list-item--with-controls .kb-list-item__controls :slotted(:first-child) {
    grid-column: 1;
    grid-row: 1;
    align-self: center;
  }

  .kb-list-item--with-controls .kb-list-item__content-row {
    grid-column: 2;
    grid-row: 1;
    align-items: center;
  }

  .kb-list-item--with-controls .kb-list-item__actions {
    grid-column: 3;
    grid-row: 1;
    align-self: center;
  }

  .kb-list-item--with-controls .kb-list-item__secondary {
    grid-column: 4;
    grid-row: 1;
    align-self: center;
  }
}
</style>
