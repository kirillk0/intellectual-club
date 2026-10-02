<template>
  <article class="row chat-list-row" :class="rowToneClass" @contextmenu="handleContextMenu">
    <div class="chat-list-row__content">
      <RouterLink custom :to="to" v-slot="{ href, navigate }">
        <a ref="primaryLinkRef" class="chat-list-row__primary" :href="href" @click="handleClick($event, navigate)">
          <div class="chat-result-main">
            <div class="chat-result-title">
              <span class="chat-result-name">{{ title }}</span>
              <span v-if="configLabel" class="chat-result-config">({{ configLabel }})</span>
            </div>
            <div class="chat-result-meta">
              <div class="muted">{{ metaText }}</div>
              <ChatGenerationStateIndicator :state="generationState" />
            </div>
            <div v-if="secondaryMeta" class="chat-result-secondary muted">{{ secondaryMeta }}</div>
            <div v-if="previewText" class="chat-first-preview">
              <div class="chat-first-preview-bubble" :class="previewToneClass">
                {{ previewText }}
              </div>
            </div>
            <div v-if="snippet" class="chat-search-snippet">
              {{ snippet }}
            </div>
          </div>
        </a>
      </RouterLink>
      <slot name="meta-extra"></slot>
    </div>

    <div class="chat-result-badges">
      <slot name="badges"></slot>
      <button
        v-if="actions"
        type="button"
        class="chat-list-row__actions-button"
        data-chat-actions-trigger
        aria-label="Chat actions"
        title="Chat actions"
        aria-haspopup="menu"
        :aria-expanded="actionsOpen"
        @click.stop="openActionsFromButton"
      >
        <SvgIcon name="more-horizontal" size="16" />
      </button>
    </div>
  </article>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue';
import { RouterLink, type RouteLocationRaw } from 'vue-router';
import type { ChatListActionsAnchor } from '@/components/ChatListActionsMenu.vue';
import ChatGenerationStateIndicator from '@/components/chat/ChatGenerationStateIndicator.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';

type GenerationState = 'generating' | 'reconnecting' | 'done';

export type ChatListRowActionsRequest = {
  anchor: ChatListActionsAnchor;
  source: 'button' | 'contextmenu';
};

interface Props {
  to: RouteLocationRaw;
  stack?: boolean;
  title: string;
  configLabel?: string | null;
  metaText: string;
  secondaryMeta?: string | null;
  previewText?: string | null;
  previewRole?: 'user' | 'assistant' | null;
  snippet?: string | null;
  generationState?: GenerationState | null;
  rowRole?: 'user' | 'assistant' | null;
  actions?: boolean;
  actionsOpen?: boolean;
}

const props = withDefaults(defineProps<Props>(), {
  stack: false,
  configLabel: null,
  secondaryMeta: null,
  previewText: null,
  previewRole: null,
  snippet: null,
  generationState: null,
  rowRole: null,
  actions: false,
  actionsOpen: false,
});

const emit = defineEmits<{
  navigate: [to: RouteLocationRaw, event: MouseEvent];
  'open-actions': [request: ChatListRowActionsRequest];
}>();

const primaryLinkRef = ref<HTMLAnchorElement | null>(null);

function openActionsFromButton(event: MouseEvent) {
  const button = event.currentTarget as HTMLElement;
  const rect = button.getBoundingClientRect();
  emit('open-actions', {
    anchor: { x: rect.right, y: rect.bottom + 4, flipY: rect.top - 4, align: 'end' },
    source: 'button',
  });
}

function handleContextMenu(event: MouseEvent) {
  if (!props.actions) return;

  // Nested links (e.g. continuation navigation) point at other chats: keep the native menu there.
  const link = (event.target as Element | null)?.closest('a');
  if (link && link !== primaryLinkRef.value) return;

  event.preventDefault();

  // Keyboard-invoked context menus report zero coordinates; anchor to the row instead.
  if (event.clientX === 0 && event.clientY === 0) {
    const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
    emit('open-actions', {
      anchor: { x: rect.left + 12, y: rect.top + 12, align: 'start' },
      source: 'contextmenu',
    });
    return;
  }

  emit('open-actions', {
    anchor: { x: event.clientX, y: event.clientY, align: 'start' },
    source: 'contextmenu',
  });
}

const isPlainLeftClick = (event: MouseEvent) =>
  event.button === 0 && !event.metaKey && !event.altKey && !event.ctrlKey && !event.shiftKey;

function handleClick(event: MouseEvent, navigate: (event?: MouseEvent) => void) {
  if (event.defaultPrevented || !isPlainLeftClick(event)) return;
  if (!props.stack) {
    navigate(event);
    return;
  }
  event.preventDefault();
  emit('navigate', props.to, event);
}

const rowToneClass = computed(() => ({
  'chat-list-row--user': props.rowRole === 'user',
  'chat-list-row--assistant': props.rowRole === 'assistant',
}));

const previewToneClass = computed(() => ({
  'chat-preview--user': props.previewRole === 'user',
  'chat-preview--assistant': props.previewRole === 'assistant',
}));
</script>

<style scoped>
.chat-list-row {
  align-items: flex-start;
}

.chat-list-row__content {
  flex: 1 1 auto;
  min-width: 0;
}

.chat-list-row__primary {
  display: block;
  min-width: 0;
  color: inherit;
  text-decoration: none;
}

.chat-list-row__primary:hover .chat-result-name {
  text-decoration: underline;
  text-underline-offset: 2px;
}

.chat-list-row__primary:focus-visible {
  outline: 2px solid var(--color-focus);
  outline-offset: 2px;
  border-radius: 6px;
}

.chat-result-title {
  display: flex;
  align-items: baseline;
  gap: 6px;
  flex-wrap: wrap;
}

.chat-result-meta {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

.chat-result-secondary {
  margin-top: 2px;
  font-size: 0.85rem;
}

.chat-result-name {
  font-weight: 600;
}

.chat-result-config {
  color: var(--color-text-muted);
  font-size: 0.85rem;
}

.chat-result-badges {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  justify-content: flex-end;
}

.chat-list-row__actions-button {
  width: 28px;
  height: 28px;
  padding: 0;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: 1px solid transparent;
  border-radius: 8px;
  background: transparent;
  color: var(--color-text-muted);
}

.chat-list-row__actions-button:hover,
.chat-list-row__actions-button[aria-expanded='true'] {
  background: var(--color-surface-hover);
  border-color: var(--color-border-strong);
  color: var(--color-text);
}

.chat-list-row__actions-button:focus-visible {
  outline: 2px solid var(--color-focus);
  outline-offset: 1px;
}

@media (hover: hover) and (pointer: fine) {
  .chat-list-row__actions-button {
    opacity: 0;
  }

  .chat-list-row:hover .chat-list-row__actions-button,
  .chat-list-row:focus-within .chat-list-row__actions-button,
  .chat-list-row__actions-button[aria-expanded='true'] {
    opacity: 1;
  }
}

.chat-search-snippet {
  margin-top: 4px;
  color: var(--color-text);
  font-size: 0.9rem;
  line-height: 1.35;
}

.chat-first-preview {
  margin-top: 6px;
}

.chat-first-preview-bubble {
  display: inline-block;
  max-width: 100%;
  padding: 6px 10px;
  border-radius: 12px;
  background: var(--color-surface-muted);
  color: var(--color-text);
  font-size: 0.9rem;
  line-height: 1.35;
  text-decoration: none;
}

.chat-first-preview-bubble.chat-preview--user {
  background: var(--color-chat-user-bg);
}

.chat-first-preview-bubble.chat-preview--assistant {
  background: var(--color-chat-assistant-bg);
}

.chat-list-row__primary:hover .chat-first-preview-bubble {
  text-decoration: none;
}

.chat-list-row--user {
  background: var(--color-chat-user-bg);
  border-color: var(--color-chat-user-border);
}

.chat-list-row--assistant {
  background: var(--color-chat-assistant-bg);
  border-color: var(--color-chat-assistant-border);
}
</style>
