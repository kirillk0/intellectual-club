<template>
  <nav
    v-if="visibleItems.length > 1"
    class="continuation-nav"
    :class="`continuation-nav--${mode}`"
    :aria-label="t('Chat continuations')"
  >
    <SvgIcon name="branch" class="continuation-nav__icon" :size="mode === 'header' ? 15 : 13" />
    <div class="continuation-nav__items">
      <template v-for="item in visibleItems" :key="item.chat_id">
        <span
          v-if="isActive(item)"
          class="continuation-nav__item continuation-nav__item--active"
          aria-current="page"
          :title="activeTitle(item)"
        >
          {{ item.label }}
        </span>
        <RouterLink v-else custom :to="chatRoute(item.chat_id)" v-slot="{ href, navigate }">
          <a
            class="continuation-nav__item continuation-nav__item--link"
            :href="href"
            :title="itemTitle(item)"
            @click="handleClick($event, navigate, item.chat_id)"
          >
            {{ item.label }}
          </a>
        </RouterLink>
      </template>
    </div>
  </nav>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import { RouterLink, type RouteLocationRaw } from 'vue-router';

import SvgIcon from '@/components/icons/SvgIcon.vue';
import { translate } from '@/i18n';
import type { ChatContinuationNavItem } from '@/types/api';

type Mode = 'header' | 'list';

const props = withDefaults(
  defineProps<{
    items?: ChatContinuationNavItem[] | null;
    currentChatId: number;
    mode?: Mode;
    stack?: boolean;
  }>(),
  {
    items: () => [],
    mode: 'list',
    stack: false,
  }
);

const emit = defineEmits<{
  navigate: [to: RouteLocationRaw, event: MouseEvent];
}>();

const t = translate;

const visibleItems = computed(() =>
  (props.items || []).filter(
    (item) =>
      item &&
      Number.isInteger(item.chat_id) &&
      item.chat_id > 0 &&
      typeof item.label === 'string' &&
      item.label.trim().length > 0
  )
);

function isActive(item: ChatContinuationNavItem) {
  return item.chat_id === props.currentChatId;
}

function itemName(item: ChatContinuationNavItem) {
  return String(item.note || item.bot_name || `Chat #${item.chat_id}`).trim() || `Chat #${item.chat_id}`;
}

function itemTitle(item: ChatContinuationNavItem) {
  return t('Continuation {label}: {title}', {
    label: item.label,
    title: itemName(item),
  });
}

function activeTitle(item: ChatContinuationNavItem) {
  return t('Current continuation {label}: {title}', {
    label: item.label,
    title: itemName(item),
  });
}

function chatRoute(chatId: number): RouteLocationRaw {
  return {
    path: `/chats/${chatId}`,
    state: props.stack ? { stack: true } : undefined,
  };
}

const isPlainLeftClick = (event: MouseEvent) =>
  event.button === 0 && !event.metaKey && !event.altKey && !event.ctrlKey && !event.shiftKey;

function handleClick(event: MouseEvent, navigate: (event?: MouseEvent) => void, chatId: number) {
  if (event.defaultPrevented || !isPlainLeftClick(event)) return;
  if (!props.stack) {
    navigate(event);
    return;
  }

  event.preventDefault();
  emit('navigate', chatRoute(chatId), event);
}
</script>

<style scoped>
.continuation-nav {
  min-width: 0;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  color: var(--color-text-muted);
}

.continuation-nav__icon {
  flex: 0 0 auto;
  stroke-width: 1.45;
}

.continuation-nav__items {
  min-width: 0;
  display: inline-flex;
  align-items: center;
  gap: 4px;
  flex-wrap: wrap;
}

.continuation-nav__item {
  flex: 0 0 auto;
  min-width: 26px;
  height: 24px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 0 7px;
  border: 1px solid var(--color-border-strong);
  border-radius: 999px;
  background: var(--color-surface-muted);
  color: var(--color-text);
  font-size: 0.78rem;
  font-weight: 600;
  line-height: 1;
  text-decoration: none;
}

.continuation-nav__item--link:hover {
  border-color: var(--color-primary);
  background: var(--color-surface-hover);
  color: var(--color-link);
}

.continuation-nav__item--link:focus-visible {
  outline: 2px solid var(--color-focus);
  outline-offset: 2px;
}

.continuation-nav__item--active {
  border-color: var(--color-primary);
  background: var(--color-primary);
  color: var(--color-primary-contrast);
  cursor: default;
}

.continuation-nav--header {
  width: 100%;
}

.continuation-nav--header .continuation-nav__items {
  overflow-x: auto;
  overflow-y: hidden;
  flex-wrap: nowrap;
  scrollbar-width: thin;
  -webkit-overflow-scrolling: touch;
}

.continuation-nav--header .continuation-nav__item {
  min-width: 22px;
  height: 18px;
  padding: 0 5px;
  font-size: 0.7rem;
}

.continuation-nav--list {
  margin-top: 6px;
}

.continuation-nav--list .continuation-nav__items {
  max-width: 100%;
}
</style>
