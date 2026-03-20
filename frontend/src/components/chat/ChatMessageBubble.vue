<template>
  <div class="message" :class="msg.role">
    <div class="bubble" :class="{ typing: msg.status === 'generating' }" :ref="setBubbleEl">
      <ChatMessageWorkingBlock
        v-if="msg.role === 'assistant'"
        :message-id="messageId"
        :message-status="msg.status || null"
        :steps="msg.steps || []"
        :open="workingOpen"
        @toggle="emit('toggle-working')"
        @step-info="(step) => emit('step-info', step)"
        @content-open="(payload) => emit('content-open', payload)"
        @attachment-open="(payload) => emit('attachment-open', payload)"
      />

      <div class="message-content">
        <template v-for="(partHtml, partIdx) in messageHtmlParts" :key="partIdx">
          <div v-html="partHtml"></div>
          <hr
            v-if="msg.role === 'assistant' && partIdx < messageHtmlParts.length - 1"
            class="message-answer-divider"
            aria-hidden="true"
          />
        </template>
      </div>

      <ChatMediaList
        v-if="messageMediaContents.length"
        :message-id="messageId"
        :contents="messageMediaContents"
        @preview="(payload) => emit('attachment-open', payload)"
      />

      <div v-if="msg.status === 'generating'" class="typing-indicator" aria-label="Assistant is typing">
        <span></span><span></span><span></span>
      </div>

      <div v-else-if="msg.status === 'error'" class="status error">
        Error: {{ msg.error_detail || 'Provider error' }}
        <button v-if="canRetry" class="link retry-link" type="button" :disabled="retrying" @click="emit('retry')">
          Retry
        </button>
      </div>

      <div v-else-if="msg.status === 'canceled'" class="status muted">
        Canceled
        <button v-if="canRetry" class="link retry-link" type="button" :disabled="retrying" @click="emit('retry')">
          Retry
        </button>
      </div>

      <div class="message-footer">
        <div class="message-meta">
          {{ metaLabel }}
          <span v-if="msg.token_count != null"> · {{ msg.token_count }} tokens</span>
          <span v-if="totalCostLabel != null"> · ${{ totalCostLabel }}</span>
        </div>
        <div class="message-actions">
          <span v-if="copied" class="copy-hint">Copied</span>
          <div class="spacer"></div>
          <button
            v-if="msg.prev_sibling_id"
            class="icon-button message-action"
            type="button"
            @click="emit('switch-branch', 'prev')"
            aria-label="Switch to previous branch"
            title="Previous branch"
          >
            ◀
          </button>
          <button class="icon-button message-action" type="button" @click="emit('copy')" :aria-label="`Copy message ${index + 1}`" title="Copy">
            📋
          </button>
          <button
            class="icon-button message-action"
            type="button"
            :disabled="!messageId || msg.status === 'generating'"
            @click="emit('edit')"
            :aria-label="`Edit message ${index + 1}`"
            title="Edit"
          >
            ✏️
          </button>
          <button
            class="icon-button message-action"
            type="button"
            :disabled="branchDisabled"
            @click="emit('branch')"
            :aria-label="`Branch from message ${index + 1}`"
            title="Branch"
          >
            🌿
          </button>
          <button
            class="icon-button message-action"
            type="button"
            :disabled="!canDelete"
            @click="emit('delete')"
            :aria-label="`Delete message ${index + 1}`"
            :title="deleteTitle"
          >
            🗑️
          </button>
          <button
            v-if="msg.next_sibling_id"
            class="icon-button message-action"
            type="button"
            @click="emit('switch-branch', 'next')"
            aria-label="Switch to next branch"
            title="Next branch"
          >
            ▶
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import ChatMediaList from '@/components/chat/ChatMediaList.vue';
import type { ChatBranchMessage, ChatMessageContent, ChatMessageStep } from '@/types/api';
import { renderChatMessageHtml as renderMessage } from '@/utils/chatMarkdown';
import ChatMessageWorkingBlock from '@/components/chat/ChatMessageWorkingBlock.vue';

interface Props {
  message: ChatBranchMessage;
  index: number;
  metaLabel?: string;
  copied?: boolean;
  retrying?: boolean;
  branchingAssistantId?: number | null;
  workingOpen?: boolean;
  canDelete?: boolean;
  deleteTitle?: string;
  registerRef?: (el: HTMLElement | null) => void;
}

const props = withDefaults(defineProps<Props>(), {
  metaLabel: '—',
  copied: false,
  retrying: false,
  branchingAssistantId: null,
  workingOpen: false,
  canDelete: false,
  deleteTitle: 'Delete',
});

const emit = defineEmits<{
  (e: 'toggle-working'): void;
  (e: 'copy'): void;
  (e: 'edit'): void;
  (e: 'branch'): void;
  (e: 'retry'): void;
  (e: 'delete'): void;
  (e: 'switch-branch', direction: 'prev' | 'next'): void;
  (e: 'step-info', step: ChatMessageStep): void;
  (e: 'content-open', payload: { messageId: number; contentId: number; title: string }): void;
  (e: 'attachment-open', payload: { messageId: number; content: ChatMessageContent }): void;
}>();

const msg = computed(() => props.message);
const messageId = computed(() => msg.value.id ?? null);

const canRetry = computed(() => Boolean(messageId.value) && (msg.value.steps || []).length > 0);

const shouldHighlightCode = computed(() => msg.value.status !== 'generating');

const sortBySequence = <T extends { sequence?: number | null }>(a: T, b: T) => {
  const aSeq = typeof a.sequence === 'number' && Number.isFinite(a.sequence) ? a.sequence : 0;
  const bSeq = typeof b.sequence === 'number' && Number.isFinite(b.sequence) ? b.sequence : 0;
  return aSeq - bSeq;
};

const joinTextContents = (contents: ChatMessageContent[] | null | undefined) => {
  const list = (contents || []).slice().sort(sortBySequence);
  return list
    .filter((c) => c && c.kind === 'text' && c.content_text)
    .map((c) => String(c.content_text ?? ''))
    .join('');
};

const messagePrimaryParts = computed(() => {
  const wantedType = msg.value.role === 'user' ? 'input' : 'answer';
  const steps = (msg.value.steps || []).slice().sort(sortBySequence);
  const parts: string[] = [];

  for (const step of steps) {
    const items = (step.items || []).slice().sort(sortBySequence);
    for (const item of items) {
      if (!item || item.type !== wantedType) continue;
      const text = joinTextContents(item.contents);
      if (text.trim()) parts.push(text);
    }
  }

  return parts;
});

const collectItemContents = (wantedTypes: string[]) => {
  const steps = (msg.value.steps || []).slice().sort(sortBySequence);
  const contents: ChatMessageContent[] = [];

  for (const step of steps) {
    const items = (step.items || []).slice().sort(sortBySequence);
    for (const item of items) {
      if (!item || !wantedTypes.includes(item.type)) continue;
      contents.push(...((item.contents || []).slice().sort(sortBySequence) as ChatMessageContent[]));
    }
  }

  return contents;
};

const messageMediaContents = computed(() => {
  if (msg.value.role === 'user') return collectItemContents(['input']).filter((content) => content.kind === 'media');
  return collectItemContents(['artifact']).filter((content) => content.kind === 'media');
});

const messageHtmlParts = computed(() =>
  messagePrimaryParts.value.map((part) =>
    renderMessage(part, { highlightCode: shouldHighlightCode.value })
  )
);

const branchDisabled = computed(() => {
  if (!messageId.value) return true;
  if (props.branchingAssistantId == null) return false;
  return props.branchingAssistantId === messageId.value;
});

const totalCostLabel = computed(() => {
  const steps = msg.value.steps || [];
  let total = 0;
  let hasCost = false;

  for (const step of steps) {
    const rawCost = step?.cost;
    if (rawCost == null) continue;
    const cost = typeof rawCost === 'number' ? rawCost : Number(rawCost);
    if (!Number.isFinite(cost)) continue;
    total += cost;
    hasCost = true;
  }

  if (!hasCost) return null;

  const roundedToCents = Math.round(total * 100) / 100;
  if (roundedToCents !== 0) return roundedToCents.toFixed(2);

  const absTotal = Math.abs(total);
  if (absTotal === 0) return '0.00';

  const decimalsForFirstSignificant = Math.ceil(-Math.log10(absTotal));
  const precision = Math.max(0, decimalsForFirstSignificant);
  const roundedToFirstSignificant =
    Math.round(total * 10 ** precision) / 10 ** precision;

  return roundedToFirstSignificant
    .toFixed(precision)
    .replace(/(\.\d*?[1-9])0+$/u, '$1')
    .replace(/\.0+$/u, '');
});

const setBubbleEl = (el: Element | null) => {
  props.registerRef?.(el as HTMLElement | null);
};
</script>

<style scoped>
.message-answer-divider {
  border: 0;
  border-top: 1px solid #d0d7de;
  margin: 10px 0;
}
</style>
