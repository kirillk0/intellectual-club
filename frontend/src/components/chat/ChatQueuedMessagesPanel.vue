<template>
  <section
    v-if="messages.length > 0"
    class="queued-messages"
    :aria-label="translate('Queued messages')"
  >
    <header class="queued-messages__header">
      <div>
        <strong>{{ translate('Queued messages') }}</strong>
        <span>{{ translate('Not sent to the model yet') }}</span>
      </div>
      <span class="queued-messages__count">{{ messages.length }}</span>
    </header>

    <ol class="queued-messages__list">
      <li v-for="message in messages" :key="message.id" class="queued-message">
        <div class="queued-message__topline">
          <div class="queued-message__badges">
            <span
              class="queued-message__badge"
              :class="`queued-message__badge--${message.kind}`"
            >
              {{ message.kind === 'steer' ? translate('Steer') : translate('Queued') }}
            </span>
            <span v-if="message.kind === 'follow_up'" class="queued-message__position">
              #{{ followUpPosition(message) }}
            </span>
            <span
              v-if="message.status === 'blocked'"
              class="queued-message__status queued-message__status--blocked"
            >
              {{ translate('Paused') }}
            </span>
            <span v-else class="queued-message__status">{{ translate('Waiting') }}</span>
          </div>
          <div class="queued-message__actions">
            <button
              type="button"
              :disabled="actionId !== null"
              :aria-label="translate('Edit queued message')"
              @click="emit('edit', message)"
            >
              {{ translate('Edit') }}
            </button>
            <button
              type="button"
              :disabled="actionId !== null"
              :aria-label="translate('Remove from queue')"
              @click="emit('remove', message)"
            >
              {{ translate('Remove from queue') }}
            </button>
            <button
              v-if="canSendNext(message)"
              class="queued-message__send-next"
              type="button"
              :disabled="actionId !== null"
              :aria-label="translate('Send next queued message')"
              @click="emit('send-next', message)"
            >
              {{ actionId === message.id ? translate('Sending…') : translate('Send next') }}
            </button>
          </div>
        </div>

        <p v-if="preview(message)" class="queued-message__preview">{{ preview(message) }}</p>
        <p v-else class="queued-message__preview queued-message__preview--muted">
          {{ translate('Attachment-only message') }}
        </p>

        <div v-if="attachments(message).length > 0" class="queued-message__attachments">
          <button
            v-for="attachment in attachments(message)"
            :key="attachment.id"
            class="queued-message__attachment"
            type="button"
            :aria-label="translate('Open attachment {name}', { name: attachment.name })"
            @click="emit('open-attachment', attachment)"
          >
            <SvgIcon :name="fileIconByMime(attachment.mimeType, attachment.name)" />
            <span>{{ attachment.name }}</span>
            <small>{{ formatFileBytes(attachment.size) }}</small>
          </button>
        </div>

        <p v-if="message.blocked_reason" class="queued-message__reason" role="status">
          {{ blockedReason(message.blocked_reason) }}
        </p>
      </li>
    </ol>
  </section>
</template>

<script setup lang="ts">
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { fileIconByMime, formatFileBytes, type ExistingChatAttachment } from '@/features/chat/attachments';
import {
  queuedMessageAttachments,
  queuedMessageText,
} from '@/features/chat/model/useChatQueueRuntime';
import type { ChatQueuedMessage } from '@/features/chat/model/chatViewModel.shared';
import { translate } from '@/i18n';

const props = defineProps<{
  messages: ChatQueuedMessage[];
  activeGenerationId: number | null;
  actionId: number | null;
  headFollowUpId: number | null;
}>();

const emit = defineEmits<{
  (event: 'edit', message: ChatQueuedMessage): void;
  (event: 'remove', message: ChatQueuedMessage): void;
  (event: 'send-next', message: ChatQueuedMessage): void;
  (event: 'open-attachment', attachment: ExistingChatAttachment): void;
}>();

const followUpPosition = (message: ChatQueuedMessage) =>
  message.position ??
  props.messages.filter((item) => item.kind === 'follow_up').findIndex((item) => item.id === message.id) + 1;

const preview = (message: ChatQueuedMessage) => {
  const text = queuedMessageText(message).trim().replace(/\s+/gu, ' ');
  return text.length > 240 ? `${text.slice(0, 237).trimEnd()}…` : text;
};

const attachments = queuedMessageAttachments;

const canSendNext = (message: ChatQueuedMessage) =>
  !props.activeGenerationId &&
  message.kind === 'follow_up' &&
  message.id === props.headFollowUpId;

const blockedReason = (reason: string) => {
  const labels: Record<string, string> = {
    generation_error: 'The previous generation failed. The queue is paused.',
    generation_canceled: 'The previous generation was canceled. The queue is paused.',
    branch_changed: 'The active branch changed. The queue is paused.',
    head_removed: 'The first queued message was removed. The queue is paused.',
    empty_message: 'This queued message no longer contains sendable content.',
  };
  return translate(labels[reason] || reason);
};
</script>

<style scoped>
.queued-messages {
  flex: 0 0 auto;
  display: grid;
  gap: 8px;
  padding: 10px 12px;
  border-top: 1px solid var(--color-border-strong);
  background: color-mix(in srgb, var(--color-info-bg) 58%, var(--color-surface));
}

.queued-messages__header,
.queued-message__topline {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
}

.queued-messages__header > div {
  display: flex;
  align-items: baseline;
  gap: 8px;
  min-width: 0;
}

.queued-messages__header strong {
  font-size: 0.86rem;
}

.queued-messages__header span {
  color: var(--color-text-muted);
  font-size: 0.76rem;
}

.queued-messages__count {
  min-width: 22px;
  padding: 2px 7px;
  border-radius: 999px;
  background: var(--color-surface-muted);
  text-align: center;
  font-variant-numeric: tabular-nums;
}

.queued-messages__list {
  display: grid;
  gap: 7px;
  max-height: min(38vh, 330px);
  margin: 0;
  padding: 0;
  overflow: auto;
  list-style: none;
}

.queued-message {
  display: grid;
  gap: 7px;
  padding: 9px 10px;
  border: 1px solid var(--color-border);
  border-radius: 9px;
  background: var(--color-surface);
}

.queued-message__badges,
.queued-message__actions,
.queued-message__attachments {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 5px;
}

.queued-message__badge,
.queued-message__position,
.queued-message__status {
  padding: 2px 7px;
  border-radius: 999px;
  font-size: 0.7rem;
  font-weight: 600;
}

.queued-message__badge--steer {
  background: color-mix(in srgb, var(--color-focus) 16%, transparent);
  color: var(--color-link);
}

.queued-message__badge--follow_up {
  background: var(--color-surface-muted);
  color: var(--color-text);
}

.queued-message__position,
.queued-message__status {
  color: var(--color-text-muted);
}

.queued-message__status--blocked {
  background: var(--color-danger-bg);
  color: var(--color-danger-text);
}

.queued-message__actions button,
.queued-message__attachment {
  min-height: 28px;
  padding: 4px 8px;
  border: 1px solid var(--color-border);
  border-radius: 7px;
  background: var(--color-surface-muted);
  color: var(--color-text);
  font-size: 0.75rem;
  cursor: pointer;
}

.queued-message__actions button:disabled {
  opacity: 0.5;
  cursor: wait;
}

.queued-message__actions .queued-message__send-next {
  border-color: transparent;
  background: var(--color-primary);
  color: var(--color-primary-contrast);
}

.queued-message__preview,
.queued-message__reason {
  margin: 0;
  overflow-wrap: anywhere;
  white-space: pre-wrap;
}

.queued-message__preview {
  font-size: 0.84rem;
}

.queued-message__preview--muted,
.queued-message__reason {
  color: var(--color-text-muted);
  font-size: 0.76rem;
}

.queued-message__reason {
  color: var(--color-danger-text);
}

.queued-message__attachment {
  display: inline-flex;
  align-items: center;
  max-width: 100%;
  gap: 5px;
}

.queued-message__attachment svg {
  flex: 0 0 auto;
}

.queued-message__attachment span {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.queued-message__attachment small {
  flex: 0 0 auto;
  color: var(--color-text-muted);
}

@media (max-width: 720px) {
  .queued-messages {
    padding: 8px;
  }

  .queued-messages__header > div,
  .queued-message__topline {
    align-items: flex-start;
    flex-direction: column;
  }

  .queued-message__actions {
    width: 100%;
  }

  .queued-message__actions button {
    flex: 1 1 auto;
  }
}
</style>
