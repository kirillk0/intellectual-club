<template>
  <component
    :is="as"
    class="row kb-list-item"
    :class="{
      'kb-list-item--with-controls': hasControls,
      'kb-list-item--button': as === 'button',
      disabled,
    }"
    :type="as === 'button' ? 'button' : undefined"
    @click="emitRootOpen"
  >
    <div v-if="hasControls" class="kb-list-item__controls">
      <slot name="leading"></slot>
      <div class="kb-list-item__controls-end">
        <span v-if="tokenText" class="kb-list-item__tokens kb-list-item__tokens--controls">(<span>{{ tokenText }}</span>)</span>
        <span v-if="badgeText" class="badge kb-list-item__badge kb-list-item__badge--controls">
          {{ badgeText }}
        </span>
        <div v-if="slots.actions" class="kb-list-item__actions" @click.stop>
          <slot name="actions"></slot>
        </div>
      </div>
    </div>

    <div class="kb-list-item__content-row">
      <div
        :class="['kb-list-item__body', bodyOpenable && 'kb-list-item__body--openable']"
        :role="bodyOpenable ? 'button' : undefined"
        :tabindex="bodyOpenable ? 0 : undefined"
        @click="emitOpen"
        @keydown.enter.prevent="emitOpen"
        @keydown.space.prevent="emitOpen"
      >
        <div class="kb-list-item__title-line">
          <span class="kb-list-item__title">{{ name }}</span>
          <span v-if="tokenText" class="kb-list-item__tokens kb-list-item__tokens--title">(<span>{{ tokenText }}</span>)</span>
          <slot name="title-extra"></slot>
        </div>
        <div v-if="meta" class="muted kb-list-item__meta">{{ meta }}</div>
      </div>

      <ImageThumbnail
        class="kb-list-item__thumbnail"
        :image="image"
        :label="name"
        :size="40"
        :hideWithoutImage="true"
      />
      <span v-if="badgeText" class="badge kb-list-item__badge kb-list-item__badge--content">
        {{ badgeText }}
      </span>
      <slot name="trailing"></slot>
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
import { formatEstimatedTokens } from '@/utils/tokens';

const props = withDefaults(
  defineProps<{
    name: string;
    image?: ImageAsset | null;
    meta?: string;
    version?: string | null;
    tokenCount?: number | string | null;
    openable?: boolean;
    disabled?: boolean;
    detailsRow?: boolean;
    as?: 'div' | 'label' | 'button';
  }>(),
  {
    image: null,
    meta: '',
    version: '',
    tokenCount: null,
    openable: false,
    disabled: false,
    detailsRow: false,
    as: 'div',
  }
);

const emit = defineEmits<{
  (e: 'open'): void;
}>();

const slots = useSlots();
const hasControls = computed(() => Boolean(props.detailsRow || slots.leading || slots.actions));
const isRootButton = computed(() => props.as === 'button');
const bodyOpenable = computed(() => Boolean(props.openable && !isRootButton.value));
const badgeText = computed(() => {
  const text = String(props.version || '').trim();
  if (!text) return '';
  if (/^v\d+/i.test(text)) return text;
  if (/^\d+$/.test(text)) return `v${text}`;
  return text;
});
const tokenText = computed(() => {
  if (props.tokenCount === null || props.tokenCount === undefined || props.tokenCount === '') return '';
  return formatEstimatedTokens(props.tokenCount);
});

const emitOpen = () => {
  if (!props.openable || isRootButton.value) return;
  emit('open');
};

const emitRootOpen = () => {
  if (!props.openable || !isRootButton.value) return;
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

.kb-list-item--button {
  width: 100%;
  text-align: left;
  background: var(--color-surface);
  border-color: var(--color-border);
  transition: background-color 0.15s ease, border-color 0.15s ease, box-shadow 0.15s ease;
}

.kb-list-item--button:hover {
  background: var(--color-surface-hover);
  border-color: var(--color-border-strong);
  box-shadow: var(--shadow-soft);
}

.kb-list-item--button:focus-visible {
  outline: 2px solid var(--color-primary);
  outline-offset: 2px;
}

.kb-list-item.disabled {
  opacity: 0.6;
}

.kb-list-item__controls {
  display: flex;
  align-items: center;
  justify-content: flex-start;
  gap: 8px;
  min-width: 0;
}

.kb-list-item__controls-end {
  display: flex;
  flex: 1 1 auto;
  align-items: center;
  justify-content: flex-start;
  gap: 8px;
  min-width: 0;
}

.kb-list-item__badge--controls {
  display: none;
}

.kb-list-item--with-controls .kb-list-item__badge--controls {
  display: inline-flex;
}

.kb-list-item--with-controls .kb-list-item__badge--content {
  display: none;
}

.kb-list-item__content-row {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  min-width: 0;
}

.kb-list-item--with-controls .kb-list-item__content-row {
  order: 1;
}

.kb-list-item--with-controls .kb-list-item__controls {
  order: 2;
}

.kb-list-item__body {
  flex: 1 1 auto;
  min-width: 0;
}

.kb-list-item__title-line {
  display: flex;
  align-items: baseline;
  gap: 5px;
  min-width: 0;
}

.kb-list-item__thumbnail,
.kb-list-item__badge {
  flex: 0 0 auto;
}

.kb-list-item__body--openable,
.kb-list-item--button {
  cursor: pointer;
}

.kb-list-item__body--openable:hover .kb-list-item__title,
.kb-list-item--button:hover .kb-list-item__title {
  text-decoration: underline;
}

.kb-list-item__body--openable:focus-visible {
  outline: 2px solid var(--color-focus);
  outline-offset: 2px;
  border-radius: 6px;
}

.kb-list-item__title-line,
.kb-list-item__title,
.kb-list-item__meta {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.kb-list-item__title {
  display: block;
  font-weight: 600;
}

.kb-list-item__tokens {
  color: var(--color-text-muted);
  font-size: 0.82rem;
  font-weight: 400;
  white-space: nowrap;
}

.kb-list-item__tokens--controls {
  display: none;
}

.kb-list-item--with-controls .kb-list-item__tokens--controls {
  display: inline-flex;
}

.kb-list-item--with-controls .kb-list-item__tokens--title {
  display: none;
}

.kb-list-item__meta {
  margin-top: 2px;
  font-size: 0.9rem;
}

.kb-list-item__actions {
  display: flex;
  margin-left: auto;
  align-items: center;
  justify-content: flex-end;
  gap: 6px;
  min-width: 0;
}

@media (min-width: 720px) {
  .kb-list-item__body {
    display: flex;
    align-items: baseline;
    gap: 8px;
  }

  .kb-list-item__meta {
    margin-top: 0;
  }
}

@container (min-width: 560px) {
  .kb-list-item--with-controls {
    grid-template-columns: auto minmax(0, 1fr) auto auto;
    align-items: center;
  }

  .kb-list-item--with-controls .kb-list-item__controls {
    display: contents;
  }

  .kb-list-item--with-controls .kb-list-item__controls-end {
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

  .kb-list-item--with-controls .kb-list-item__badge--controls {
    display: none;
  }

  .kb-list-item--with-controls .kb-list-item__tokens--controls {
    display: none;
  }

  .kb-list-item--with-controls .kb-list-item__badge--content {
    display: inline-flex;
  }

  .kb-list-item--with-controls .kb-list-item__tokens--title {
    display: inline-flex;
  }

  .kb-list-item--with-controls .kb-list-item__secondary {
    grid-column: 4;
    grid-row: 1;
    align-self: center;
  }
}
</style>
