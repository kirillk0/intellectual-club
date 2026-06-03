<template>
  <div class="message" :class="msg.role">
    <div class="bubble" :class="{ typing: msg.status === 'generating' }" :ref="setBubbleEl">
      <ChatMessageWorkingBlock
        v-if="msg.role === 'assistant'"
        :message-id="messageId"
        :message-status="msg.status || null"
        :summary="msg.working || null"
        :step-index="workingState?.steps || []"
        :selected-step="workingState?.selectedStep || null"
        :loading="Boolean(workingState?.loading)"
        :error="workingState?.error || ''"
        :open="workingOpen"
        @toggle="emit('toggle-working')"
        @step-select="(stepId) => emit('working-step-select', stepId)"
        @step-info="(step) => emit('step-info', step)"
        @content-open="(payload) => emit('content-open', payload)"
        @attachment-open="(payload) => emit('attachment-open', { ...payload, contents: previewAttachmentContents })"
      />

      <div class="message-content" @click="handleMessageContentClick">
        <template v-for="(part, partIdx) in messageParts" :key="part.key">
          <div class="message-answer-part">
            <span v-if="part.showTimestamp && part.timestamp" class="message-answer-time">
              {{ part.timestamp }}
            </span>
            <div v-html="part.html"></div>
          </div>
          <hr
            v-if="msg.role === 'assistant' && partIdx < messageParts.length - 1"
            class="message-answer-divider"
            aria-hidden="true"
          />
        </template>
      </div>

      <ChatMediaList
        v-if="messageMediaContents.length"
        :message-id="messageId"
        :contents="messageMediaContents"
        @preview="(payload) => emit('attachment-open', { ...payload, contents: previewAttachmentContents })"
      />

      <div
        v-if="msg.status === 'generating' && pollReconnecting"
        class="reconnect-indicator"
        role="status"
        aria-label="Reconnecting"
        title="Reconnecting"
      ></div>
      <div v-else-if="msg.status === 'generating'" class="typing-indicator" aria-label="Assistant is typing">
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
            v-if="!readonly && msg.prev_sibling_id"
            class="icon-button message-action"
            type="button"
            @click="emit('switch-branch', 'prev')"
            aria-label="Switch to previous branch"
            title="Previous branch"
          >
            <SvgIcon name="chevron-left" />
          </button>
          <button class="icon-button message-action" type="button" @click="emit('copy')" :aria-label="`Copy message ${index + 1}`" title="Copy">
            <SvgIcon name="copy" />
          </button>
          <button
            v-if="!readonly"
            class="icon-button message-action"
            :class="{ active: Boolean(msg.bookmarked) }"
            type="button"
            :disabled="!messageId || bookmarking"
            :aria-label="bookmarkLabel"
            :aria-pressed="bookmarkPressed"
            :title="bookmarkTitle"
            @click="emit('toggle-bookmark')"
          >
            <SvgIcon name="bookmark" />
          </button>
          <button
            v-if="!readonly"
            class="icon-button message-action"
            type="button"
            :disabled="!messageId || msg.status === 'generating'"
            @click="emit('edit')"
            :aria-label="`Edit message ${index + 1}`"
            title="Edit"
          >
            <SvgIcon name="edit" />
          </button>
          <button
            v-if="!readonly"
            class="icon-button message-action"
            type="button"
            :disabled="branchDisabled"
            @click="emit('branch')"
            :aria-label="`Branch from message ${index + 1}`"
            title="Branch"
          >
            <SvgIcon name="branch" />
          </button>
          <button
            v-if="!readonly"
            class="icon-button message-action"
            type="button"
            :disabled="!canDelete"
            @click="emit('delete')"
            :aria-label="`Delete message ${index + 1}`"
            :title="deleteTitle"
          >
            <SvgIcon name="delete" />
          </button>
          <button
            v-if="!readonly && msg.next_sibling_id"
            class="icon-button message-action"
            type="button"
            @click="emit('switch-branch', 'next')"
            aria-label="Switch to next branch"
            title="Next branch"
          >
            <SvgIcon name="chevron-right" />
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import ChatMediaList from '@/components/chat/ChatMediaList.vue';
import type { OpenWorkingState } from '@/features/chat/model/useChatMessageActions';
import type { ChatBranchMessage, ChatMessageContent, ChatMessageStep } from '@/types/api';
import { renderChatMessageHtml as renderMessage } from '@/utils/chatMarkdown';
import ChatMessageWorkingBlock from '@/components/chat/ChatMessageWorkingBlock.vue';
import { formatTimeOfDay } from '@/utils/dates';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { copyTextWithFallback } from '@/utils/clipboard';

interface Props {
  message: ChatBranchMessage;
  index: number;
  metaLabel?: string;
  copied?: boolean;
  retrying?: boolean;
  bookmarking?: boolean;
  branchingAssistantId?: number | null;
  pollReconnecting?: boolean;
  workingOpen?: boolean;
  workingState?: OpenWorkingState | null;
  canDelete?: boolean;
  deleteTitle?: string;
  readonly?: boolean;
  registerRef?: (el: HTMLElement | null) => void;
}

const props = withDefaults(defineProps<Props>(), {
  metaLabel: '—',
  copied: false,
  retrying: false,
  bookmarking: false,
  branchingAssistantId: null,
  pollReconnecting: false,
  workingOpen: false,
  workingState: null,
  canDelete: false,
  deleteTitle: 'Delete',
  readonly: false,
});

const emit = defineEmits<{
  (e: 'toggle-working'): void;
  (e: 'copy'): void;
  (e: 'toggle-bookmark'): void;
  (e: 'edit'): void;
  (e: 'branch'): void;
  (e: 'retry'): void;
  (e: 'delete'): void;
  (e: 'switch-branch', direction: 'prev' | 'next'): void;
  (e: 'working-step-select', stepId: number): void;
  (e: 'step-info', step: ChatMessageStep): void;
  (e: 'content-open', payload: { messageId: number; contentId: number; title: string }): void;
  (e: 'attachment-open', payload: { messageId: number; content: ChatMessageContent; contents?: ChatMessageContent[] }): void;
}>();

const msg = computed(() => props.message);
const messageId = computed(() => msg.value.id ?? null);
const bookmarkPressed = computed(() => String(Boolean(msg.value.bookmarked)));
const bookmarkTitle = computed(() => (msg.value.bookmarked ? 'Remove bookmark' : 'Add bookmark'));
const bookmarkLabel = computed(() =>
  msg.value.bookmarked ? `Remove bookmark for message ${props.index + 1}` : `Add bookmark for message ${props.index + 1}`
);

const canRetry = computed(
  () => !props.readonly && Boolean(messageId.value) && (msg.value.working?.step_count || 0) > 0
);

const shouldHighlightCode = computed(() => msg.value.status !== 'generating');

const sortBySequence = <T extends { sequence?: number | null }>(a: T, b: T) => {
  const aSeq = typeof a.sequence === 'number' && Number.isFinite(a.sequence) ? a.sequence : 0;
  const bSeq = typeof b.sequence === 'number' && Number.isFinite(b.sequence) ? b.sequence : 0;
  return aSeq - bSeq;
};

type MessagePart = {
  key: string;
  html: string;
  timestamp: string;
  showTimestamp: boolean;
};

const messageParts = computed<MessagePart[]>(() => {
  const parts: MessagePart[] = [];

  for (const [index, part] of [...(msg.value.content?.parts || [])].sort(sortBySequence).entries()) {
    const text = String(part.text ?? '');
    if (!text.trim()) continue;

    parts.push({
      key:
        typeof part.content_id === 'number' && part.content_id > 0
          ? `content-${part.content_id}`
          : `content-${part.step_sequence || 0}-${part.item_sequence || 0}-${part.sequence || index}`,
      html: renderMessage(text, { highlightCode: shouldHighlightCode.value, codeCopyButtons: true }),
      timestamp: formatTimeOfDay(part.created_at),
      showTimestamp: msg.value.role === 'assistant',
    });
  }

  if (msg.value.role === 'assistant' && msg.value.status !== 'generating' && parts.length > 0) {
    parts[parts.length - 1] = {
      ...parts[parts.length - 1],
      showTimestamp: false,
    };
  }

  return parts;
});

const messageMediaContents = computed(() =>
  (msg.value.content?.media || []).slice().sort(sortBySequence).filter((content) => content.kind === 'media')
);

const previewAttachmentContents = computed(() => messageMediaContents.value);

const branchDisabled = computed(() => {
  if (!messageId.value) return true;
  if (props.readonly) return true;
  if (props.branchingAssistantId == null) return false;
  return props.branchingAssistantId === messageId.value;
});

const totalCostLabel = computed(() => {
  const rawTotal = msg.value.usage?.total_cost;
  if (rawTotal == null) return null;
  const total = typeof rawTotal === 'number' ? rawTotal : Number(rawTotal);
  if (!Number.isFinite(total)) return null;

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

const setCopyButtonState = (button: HTMLButtonElement, copied: boolean) => {
  button.setAttribute('aria-label', copied ? 'Code copied' : 'Copy code');
  button.setAttribute('title', copied ? 'Code copied' : 'Copy code');
  button.classList.toggle('copied', copied);
};

const handleMessageContentClick = async (event: MouseEvent) => {
  const target = event.target;
  if (!(target instanceof Element)) return;

  const button = target.closest<HTMLButtonElement>('button[data-code-copy-button="true"]');
  if (!button) return;

  const code = button.closest('.code-copy-block')?.querySelector('pre > code');
  const text = code?.textContent ?? '';
  if (!text) return;

  event.preventDefault();
  event.stopPropagation();

  const copied = await copyTextWithFallback(text, { promptLabel: 'Copy the code manually:' });
  if (!copied) return;

  setCopyButtonState(button, true);
  window.setTimeout(() => setCopyButtonState(button, false), 1200);
};
</script>

<style scoped>
.message-answer-part::after {
  content: '';
  display: block;
  clear: both;
}

.message-answer-divider {
  border: 0;
  border-top: 1px solid var(--color-border-strong);
  margin: 10px 0;
}

.message-answer-time {
  float: right;
  margin-left: 12px;
  margin-bottom: 4px;
  font-size: 0.78rem;
  line-height: 1.5;
  color: var(--color-text-muted);
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
</style>
