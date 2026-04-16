<template>
  <section class="card stack chat-bot-filters-panel">
    <div class="chat-bot-filters-panel__header">
      <strong>Bots</strong>
      <div class="chat-bot-filters-panel__header-actions">
        <button type="button" class="link" :disabled="!hasActiveFilter" @click="emit('clear-filter')">Clear</button>
        <slot name="header-extra"></slot>
      </div>
    </div>

    <div class="chat-bot-filters-panel__search">
      <input
        :value="searchTerm"
        type="search"
        class="full"
        placeholder="Search bots"
        aria-label="Search bots"
        @input="emitSearchInput"
      />
      <button
        type="button"
        class="chat-bot-filters-panel__sort-toggle"
        :class="{ active: sortMode === 'recent_activity' }"
        :aria-label="sortToggleLabel"
        :title="sortToggleLabel"
        @click="emit('toggle-sort')"
      >
        <SvgIcon :name="sortMode === 'recent_activity' ? 'sort-time' : 'sort-alpha'" />
      </button>
      <button v-if="searchTerm" type="button" @click="emit('update:searchTerm', '')">Clear</button>
    </div>

    <div class="list chat-bot-filters-panel__list">
      <button
        type="button"
        class="row chat-bot-filters-panel__item"
        :class="{ active: selectedFilter === '' }"
        @click="emit('select-filter', '')"
      >
        <span class="chat-bot-filters-panel__name">All bots</span>
        <ImageThumbnail :label="'All bots'" :size="36" :hideWithoutImage="true" />
        <span class="muted chat-bot-filters-panel__count">{{ allBotsCount }}</span>
      </button>

      <button
        v-for="opt in options"
        :key="opt.value"
        type="button"
        class="row chat-bot-filters-panel__item"
        :class="{ active: selectedFilter === opt.value }"
        @click="emit('select-filter', opt.value)"
      >
        <span class="chat-bot-filters-panel__name">{{ opt.label }}</span>
        <ImageThumbnail :image="opt.image" :label="opt.label" :size="36" :hideWithoutImage="true" />
        <span class="muted chat-bot-filters-panel__count">{{ opt.count }}</span>
      </button>

      <p v-if="emptyState" class="muted">{{ emptyState }}</p>
    </div>
  </section>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import ImageThumbnail from '@/components/ImageThumbnail.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import type { ImageAsset } from '@/types/api';

type ChatBotFilterOption = {
  value: string;
  label: string;
  image: ImageAsset | null;
  count: number;
};

const props = defineProps<{
  searchTerm: string;
  sortMode: 'name' | 'recent_activity';
  selectedFilter: string;
  hasActiveFilter: boolean;
  allBotsCount: number;
  options: ChatBotFilterOption[];
  emptyState: string;
}>();

const emit = defineEmits<{
  (e: 'update:searchTerm', value: string): void;
  (e: 'toggle-sort'): void;
  (e: 'select-filter', value: string): void;
  (e: 'clear-filter'): void;
}>();

const sortToggleLabel = computed(() => {
  return props.sortMode === 'recent_activity'
    ? 'Sort: Recent activity. Switch to Name.'
    : 'Sort: Name. Switch to Recent activity.';
});

function emitSearchInput(event: Event) {
  const value = event.target instanceof HTMLInputElement ? event.target.value : '';
  emit('update:searchTerm', value);
}
</script>

<style scoped>
.chat-bot-filters-panel {
  gap: 10px;
}

.chat-bot-filters-panel__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.chat-bot-filters-panel__header-actions {
  display: inline-flex;
  align-items: center;
  gap: 6px;
}

.chat-bot-filters-panel__search {
  display: flex;
  align-items: center;
  gap: 8px;
}

.chat-bot-filters-panel__sort-toggle {
  width: 34px;
  min-width: 34px;
  height: 34px;
  border-radius: 10px;
  border: 1px solid #d2d8e2;
  background: #fff;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: #4b5563;
  padding: 0;
  line-height: 1;
}

.chat-bot-filters-panel__sort-toggle:hover {
  border-color: #b7c5dc;
}

.chat-bot-filters-panel__sort-toggle.active {
  background: #f1f7ff;
  border-color: #b8d6ff;
  color: #1d4ed8;
}

.chat-bot-filters-panel__list {
  gap: 6px;
}

.chat-bot-filters-panel__item {
  cursor: pointer;
  text-align: left;
  background: #fff;
  padding: 8px 10px;
  justify-content: flex-start;
}

.chat-bot-filters-panel__item.active {
  background: #f1f7ff;
  border-color: #b8d6ff;
}

.chat-bot-filters-panel__name {
  font-weight: 600;
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
}

.chat-bot-filters-panel__count {
  margin-left: auto;
  flex: 0 0 auto;
}
</style>
