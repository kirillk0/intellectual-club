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

      <div ref="messageContentEl" class="message-content" @click="handleMessageContentClick">
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
          <span class="message-number">#{{ index + 1 }}</span>
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
            type="button"
            :disabled="branchDisabled"
            @click="emit('branch')"
            :aria-label="`Branch from message ${index + 1}`"
            title="Branch"
          >
            <SvgIcon name="branch" />
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
          <button
            v-if="showMoreActions"
            ref="moreMenuButtonRef"
            class="icon-button message-action"
            type="button"
            aria-haspopup="menu"
            :aria-expanded="moreMenuOpen"
            :aria-label="`More actions for message ${index + 1}`"
            title="More actions"
            @click.stop="toggleMoreMenu"
          >
            <SvgIcon name="more-horizontal" />
          </button>
        </div>
      </div>

      <Teleport to="body">
        <div
          v-if="moreMenuOpen"
          ref="moreMenuRef"
          class="dropdown floating-dropdown message-actions-menu"
          role="menu"
          :style="moreMenuStyle"
        >
          <button
            class="menu-item message-actions-menu__item"
            :class="{ 'message-actions-menu__item--active': Boolean(msg.bookmarked) }"
            type="button"
            role="menuitemcheckbox"
            :disabled="!messageId || bookmarking"
            :aria-label="bookmarkLabel"
            :aria-checked="bookmarkPressed"
            @click="emitBookmark"
          >
            <span
              class="message-actions-menu__icon"
              :class="{ 'message-actions-menu__icon--active': Boolean(msg.bookmarked) }"
            >
              <SvgIcon name="bookmark" size="16" />
            </span>
            <span class="message-actions-menu__label">Bookmark</span>
          </button>
          <button
            class="menu-item message-actions-menu__item"
            type="button"
            role="menuitem"
            :disabled="!messageId || msg.status === 'generating'"
            :aria-label="`Edit message ${index + 1}`"
            @click="emitEdit"
          >
            <span class="message-actions-menu__icon">
              <SvgIcon name="edit" size="16" />
            </span>
            <span class="message-actions-menu__label">Edit</span>
          </button>
          <button
            class="menu-item message-actions-menu__item"
            type="button"
            role="menuitem"
            :disabled="branchToNewChatDisabled"
            :aria-label="`Branch message ${index + 1} to new chat`"
            title="Branch to new chat"
            @click="emitBranchNewChat"
          >
            <span class="message-actions-menu__icon">
              <SvgIcon name="branch" size="16" />
            </span>
            <span class="message-actions-menu__label">Branch to new chat</span>
          </button>
          <button
            v-if="canMoveBranchToNewChat"
            class="menu-item message-actions-menu__item"
            type="button"
            role="menuitem"
            :disabled="moveBranchToNewChatDisabled"
            :aria-label="moveBranchToNewChatAriaLabel"
            :title="moveBranchToNewChatTitle"
            @click="emitMoveBranchNewChat"
          >
            <span class="message-actions-menu__icon">
              <SvgIcon name="branch" size="16" />
            </span>
            <span class="message-actions-menu__label">{{ moveBranchToNewChatLabel }}</span>
          </button>
          <button
            class="menu-item message-actions-menu__item danger"
            type="button"
            role="menuitem"
            :disabled="!canDelete"
            :aria-label="`Delete message ${index + 1}`"
            :title="deleteTitle"
            @click="emitDelete"
          >
            <span class="message-actions-menu__icon">
              <SvgIcon name="delete" size="16" />
            </span>
            <span class="message-actions-menu__label">Delete</span>
          </button>
        </div>
      </Teleport>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, onUpdated, ref, watch, type ComponentPublicInstance } from 'vue';

import ChatMediaList from '@/components/chat/ChatMediaList.vue';
import type { OpenWorkingState } from '@/features/chat/model/useChatMessageActions';
import type { ChatBranchMessage, ChatMessageContent, ChatMessageStep } from '@/types/api';
import { enhanceRenderedChatMessageHtml, renderChatMessageHtml as renderMessage } from '@/utils/chatMarkdown';
import ChatMessageWorkingBlock from '@/components/chat/ChatMessageWorkingBlock.vue';
import { formatTimeOfDay } from '@/utils/dates';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { copyTextWithFallback } from '@/utils/clipboard';
import { translate } from '@/i18n';

interface Props {
  message: ChatBranchMessage;
  index: number;
  metaLabel?: string;
  copied?: boolean;
  retrying?: boolean;
  bookmarking?: boolean;
  branchingAssistantId?: number | null;
  branchingNewChatMessageId?: number | null;
  movingBranchToNewChatMessageId?: number | null;
  pollReconnecting?: boolean;
  workingOpen?: boolean;
  workingState?: OpenWorkingState | null;
  canDelete?: boolean;
  deleteTitle?: string;
  readonly?: boolean;
  registerRef?: (el: HTMLElement | null) => void;
}

type TemplateRefValue = Element | ComponentPublicInstance | null;

const props = withDefaults(defineProps<Props>(), {
  metaLabel: '—',
  copied: false,
  retrying: false,
  bookmarking: false,
  branchingAssistantId: null,
  branchingNewChatMessageId: null,
  movingBranchToNewChatMessageId: null,
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
  (e: 'branch-new-chat'): void;
  (e: 'move-branch-new-chat'): void;
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
const bookmarkPressed = computed(() => Boolean(msg.value.bookmarked));
const bookmarkLabel = computed(() =>
  msg.value.bookmarked ? `Remove bookmark for message ${props.index + 1}` : `Add bookmark for message ${props.index + 1}`
);
const showMoreActions = computed(() => !props.readonly);
const moreMenuOpen = ref(false);
const moreMenuRef = ref<HTMLElement | null>(null);
const moreMenuButtonRef = ref<HTMLElement | null>(null);
const moreMenuStyle = ref<Record<string, string>>({});
const messageContentEl = ref<HTMLElement | null>(null);
let enhanceMessageContentToken = 0;

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

const branchToNewChatDisabled = computed(() => {
  if (!messageId.value) return true;
  if (props.readonly) return true;
  if (props.branchingNewChatMessageId == null) return false;
  return true;
});

const hasSiblingBranches = computed(() => {
  if ((msg.value.siblings || []).length > 1) return true;
  return Boolean(msg.value.prev_sibling_id || msg.value.next_sibling_id);
});

const canMoveBranchToNewChat = computed(() => !props.readonly && hasSiblingBranches.value);

const moveBranchToNewChatDisabled = computed(() => {
  if (!messageId.value) return true;
  if (props.readonly) return true;
  if (msg.value.status === 'generating') return true;
  if (props.movingBranchToNewChatMessageId == null) return false;
  return true;
});

const moveBranchToNewChatLabel = computed(() =>
  props.movingBranchToNewChatMessageId === messageId.value
    ? translate('Moving branch…')
    : translate('Move branch to new chat')
);

const moveBranchToNewChatTitle = computed(() => translate('Move branch to new chat'));
const moveBranchToNewChatAriaLabel = computed(() =>
  translate(`Move branch from message ${props.index + 1} to new chat`)
);

const updateMoreMenuPosition = () => {
  if (!moreMenuOpen.value) return;

  const button = moreMenuButtonRef.value;
  if (!button) return;

  const rect = button.getBoundingClientRect();
  const viewportPadding = 8;
  const gap = 6;
  const preferredWidth = 190;
  const minWidth = 170;
  const maxWidth = Math.max(minWidth, window.innerWidth - viewportPadding * 2);
  const width = Math.min(preferredWidth, maxWidth);
  const menuHeight = moreMenuRef.value?.scrollHeight ?? 0;
  const spaceBelow = Math.max(0, window.innerHeight - rect.bottom - gap - viewportPadding);
  const spaceAbove = Math.max(0, rect.top - gap - viewportPadding);
  const openAbove = menuHeight > spaceBelow && spaceAbove > spaceBelow;
  const availableHeight = Math.max(120, openAbove ? spaceAbove : spaceBelow);
  const clampedHeight = menuHeight > 0 ? Math.min(menuHeight, availableHeight) : availableHeight;
  const top = openAbove
    ? Math.max(viewportPadding, rect.top - gap - clampedHeight)
    : Math.min(rect.bottom + gap, window.innerHeight - viewportPadding - clampedHeight);
  const left = Math.min(
    Math.max(viewportPadding, rect.right - width),
    Math.max(viewportPadding, window.innerWidth - width - viewportPadding)
  );

  moreMenuStyle.value = {
    position: 'fixed',
    top: `${top}px`,
    left: `${left}px`,
    right: 'auto',
    width: `${width}px`,
    maxWidth: `${maxWidth}px`,
    maxHeight: `${availableHeight}px`,
    overflowY: 'auto',
    zIndex: '2000',
  };
};

const handleMoreMenuClickOutside = (event: MouseEvent) => {
  const target = event.target as Node | null;
  if (!target) return;
  if (moreMenuRef.value?.contains(target)) return;
  if (moreMenuButtonRef.value?.contains(target)) return;
  closeMoreMenu();
};

const handleMoreMenuKeydown = (event: KeyboardEvent) => {
  if (event.key !== 'Escape') return;
  closeMoreMenu();
};

const addMoreMenuListeners = () => {
  document.addEventListener('click', handleMoreMenuClickOutside, true);
  window.addEventListener('keydown', handleMoreMenuKeydown);
  window.addEventListener('resize', updateMoreMenuPosition);
  window.addEventListener('scroll', updateMoreMenuPosition, true);
};

const removeMoreMenuListeners = () => {
  document.removeEventListener('click', handleMoreMenuClickOutside, true);
  window.removeEventListener('keydown', handleMoreMenuKeydown);
  window.removeEventListener('resize', updateMoreMenuPosition);
  window.removeEventListener('scroll', updateMoreMenuPosition, true);
};

const closeMoreMenu = () => {
  if (!moreMenuOpen.value) return;
  moreMenuOpen.value = false;
  moreMenuStyle.value = {};
  removeMoreMenuListeners();
};

const openMoreMenu = async () => {
  if (!showMoreActions.value) return;
  moreMenuOpen.value = true;
  addMoreMenuListeners();
  await nextTick();
  updateMoreMenuPosition();
};

const toggleMoreMenu = async () => {
  if (moreMenuOpen.value) {
    closeMoreMenu();
    return;
  }

  await openMoreMenu();
};

const emitBookmark = () => {
  if (!messageId.value || props.bookmarking) return;
  closeMoreMenu();
  emit('toggle-bookmark');
};

const emitEdit = () => {
  if (!messageId.value || msg.value.status === 'generating') return;
  closeMoreMenu();
  emit('edit');
};

const emitBranchNewChat = () => {
  if (branchToNewChatDisabled.value) return;
  closeMoreMenu();
  emit('branch-new-chat');
};

const emitMoveBranchNewChat = () => {
  if (moveBranchToNewChatDisabled.value) return;
  closeMoreMenu();
  emit('move-branch-new-chat');
};

const emitDelete = () => {
  if (!props.canDelete) return;
  closeMoreMenu();
  emit('delete');
};

watch(showMoreActions, (visible) => {
  if (!visible) closeMoreMenu();
});

watch(messageId, () => {
  closeMoreMenu();
});

const scheduleEnhanceMessageContent = () => {
  const token = ++enhanceMessageContentToken;

  void nextTick(async () => {
    const root = messageContentEl.value;
    if (!root || token !== enhanceMessageContentToken) return;
    await enhanceRenderedChatMessageHtml(root, { highlightCode: shouldHighlightCode.value });
  });
};

onMounted(scheduleEnhanceMessageContent);
onUpdated(scheduleEnhanceMessageContent);

onBeforeUnmount(() => {
  enhanceMessageContentToken += 1;
  removeMoreMenuListeners();
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

const setBubbleEl = (el: TemplateRefValue) => {
  props.registerRef?.(el instanceof HTMLElement ? el : null);
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

.message-actions-menu {
  min-width: 170px;
}

.message-actions-menu__item {
  display: flex;
  align-items: center;
  gap: 10px;
  line-height: 1.2;
  color: var(--color-text);
}

.message-actions-menu__icon {
  width: 22px;
  height: 22px;
  border-radius: 6px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: 0 0 auto;
  color: var(--color-text-muted);
}

.message-actions-menu__icon :deep(.svg-icon) {
  flex: 0 0 auto;
  stroke-width: 1.4;
}

.message-actions-menu__icon--active {
  background: var(--color-primary);
  color: var(--color-primary-contrast);
}

.message-actions-menu__icon--active :deep(.svg-icon) {
  stroke-width: 1.8;
}

.message-actions-menu__item.danger {
  color: var(--color-danger);
}

.message-actions-menu__item.danger .message-actions-menu__icon {
  color: var(--color-danger);
}

.message-actions-menu__item:disabled {
  cursor: not-allowed;
  opacity: 0.55;
}

.message-actions-menu__label {
  flex: 1;
  min-width: 0;
  overflow-wrap: break-word;
  white-space: normal;
}
</style>
