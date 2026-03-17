<template>
  <div class="trace-block">
    <template v-if="stepGroups.length">
      <div v-for="group in stepGroups" :key="group.key" class="trace-step">
        <div class="trace-step-header">
          <button
            v-if="canInspectStep(group.step)"
            class="link trace-step-title trace-step-title-button"
            type="button"
            @click.stop.prevent="openStep(group.step)"
          >
            Step {{ group.sequence }}
          </button>
          <span v-else class="trace-step-title">Step {{ group.sequence }}</span>
          <span v-if="group.createdAt" class="trace-step-time">{{ formatIso(group.createdAt) }}</span>
        </div>

        <div v-for="item in group.normalItems" :key="itemKey(item, group.sequence)" class="trace-item">
          <template v-if="isPrimaryItem(item)">
            <div
              v-if="itemText(item).trim()"
              class="trace-item-body"
              v-html="renderHtml(itemText(item))"
            ></div>
            <ChatMediaList
              v-else-if="itemMedia(item).length"
              :message-id="messageId"
              :contents="itemMedia(item)"
            />
            <div v-else class="trace-item-body muted">No data</div>
          </template>

          <template v-else>
            <details class="trace-item-details">
              <summary class="trace-item-summary">{{ itemSummary(item) }}</summary>
              <div
                v-if="itemText(item).trim()"
                class="trace-item-body"
                v-html="renderHtml(itemText(item))"
              ></div>
              <ChatMediaList
                v-else-if="itemMedia(item).length"
                :message-id="messageId"
                :contents="itemMedia(item)"
              />
              <div v-else class="trace-item-body muted">No data</div>
            </details>
          </template>
        </div>

        <div
          v-for="row in group.toolRows"
          :key="toolRowKey(row, group.sequence)"
          class="trace-tool-row"
          :class="{ 'trace-tool-row--single': !row.call || !row.result }"
        >
          <details
            v-if="row.call"
            :key="itemKey(row.call, group.sequence)"
            class="trace-item-details trace-item-details--tool"
          >
            <summary class="trace-item-summary">{{ itemSummary(row.call) }}</summary>
            <div v-if="itemText(row.call).trim()" class="trace-item-body" v-html="renderHtml(itemText(row.call))"></div>
            <div v-else class="trace-item-body muted">No data</div>
          </details>

          <details
            v-if="row.result"
            :key="itemKey(row.result, group.sequence)"
            class="trace-item-details trace-item-details--tool"
          >
            <summary class="trace-item-summary">{{ itemSummary(row.result) }}</summary>
            <div
              v-if="itemText(row.result).trim()"
              class="trace-item-body"
              v-html="renderHtml(itemText(row.result))"
            ></div>
            <ChatMediaList
              v-else-if="itemMedia(row.result).length"
              :message-id="messageId"
              :contents="itemMedia(row.result)"
            />
            <div v-else class="trace-item-body muted">No data</div>
            <div v-if="canOpenFullText(row.result)" class="trace-item-more">
              <button
                class="link trace-item-more-link"
                type="button"
                @click.stop.prevent="openFullText(row.result, 'Tool result full text')"
              >
                Read more
              </button>
            </div>
          </details>
        </div>
      </div>
    </template>

    <div v-else class="muted">No content</div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import ChatMediaList from '@/components/chat/ChatMediaList.vue';
import type { ChatBranchMessage, ChatMessageContent, ChatMessageItem, ChatMessageStep } from '@/types/api';
import { joinItemTextContents } from '@/utils/chatItemText';
import { renderChatMessageHtml as renderMessage } from '@/utils/chatMarkdown';
import { formatRelativeDateTime } from '@/utils/dates';

interface Props {
  message: ChatBranchMessage;
}

const props = defineProps<Props>();
const emit = defineEmits<{
  (e: 'step-open', payload: { messageId: number; step: ChatMessageStep; closed: boolean }): void;
  (e: 'content-open', payload: { messageId: number; contentId: number; title: string }): void;
}>();

const formatIso = (iso: string | null | undefined) => {
  return formatRelativeDateTime(iso);
};

const sortBySeq = <T extends { sequence: number }>(a: T, b: T) => a.sequence - b.sequence;

const messageId = computed(() => (typeof props.message.id === 'number' ? props.message.id : null));
const stepDetailsEnabled = computed(() => props.message.role === 'assistant' && messageId.value != null);
const isMessageFinished = computed(() => props.message.status !== 'generating');

const isStepClosed = (step: ChatMessageStep) => Boolean(step.response_final) || isMessageFinished.value;
const canInspectStep = (step: ChatMessageStep) =>
  stepDetailsEnabled.value && typeof step.id === 'number' && step.id > 0 && messageId.value != null;

const openStep = (step: ChatMessageStep) => {
  if (!canInspectStep(step) || messageId.value == null) return;
  emit('step-open', { messageId: messageId.value, step, closed: isStepClosed(step) });
};

const firstTruncatedTextContentId = (item: ChatMessageItem): number | null => {
  const contents = (item.contents || []).slice().sort(sortBySeq);
  for (const content of contents) {
    if (content.kind !== 'text') continue;
    if (!content.content_text_truncated) continue;
    if (typeof content.id === 'number' && content.id > 0) return content.id;
  }
  return null;
};

const canOpenFullText = (item: ChatMessageItem) => {
  if (item.type !== 'tool_result') return false;
  if (messageId.value == null) return false;
  return firstTruncatedTextContentId(item) != null;
};

const openFullText = (item: ChatMessageItem, title: string) => {
  if (messageId.value == null) return;
  const contentId = firstTruncatedTextContentId(item);
  if (contentId == null) return;
  emit('content-open', { messageId: messageId.value, contentId, title });
};

const asRecord = (value: unknown): Record<string, unknown> | null => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
};

const itemOpaquePayload = (item: ChatMessageItem): Record<string, unknown> | null => {
  const contents = (item.contents || []).slice().sort(sortBySeq);
  for (const content of contents) {
    if (content.kind !== 'opaque') continue;
    const payload = asRecord(content.content_json);
    if (payload) return payload;
  }
  return null;
};

const toolCallIdFromPayload = (payload: Record<string, unknown> | null): string | null => {
  if (!payload) return null;

  const direct = payload.tool_call_id ?? payload.call_id;
  if (typeof direct === 'string' || typeof direct === 'number') return String(direct);

  const responsesItem = asRecord(payload.responses_item);
  const nested = responsesItem?.call_id;
  if (typeof nested === 'string' || typeof nested === 'number') return String(nested);

  return null;
};

const toolCallId = (item: ChatMessageItem): string | null => {
  return toolCallIdFromPayload(itemOpaquePayload(item));
};

const normalizeSequence = (value: unknown, fallback: number) => {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  return fallback;
};

const isToolItem = (item: ChatMessageItem) => item.type === 'tool_call' || item.type === 'tool_result';

const reorderTraceItemsForDisplay = (items: ChatMessageItem[]) => {
  const sorted = (items || []).slice().sort(sortBySeq);
  const callSequenceById = new Map<string, number>();

  for (const item of sorted) {
    if (item.type !== 'tool_call') continue;
    const callId = toolCallId(item);
    if (!callId) continue;
    callSequenceById.set(callId, normalizeSequence(item.sequence, 0));
  }

  return sorted.slice().sort((a, b) => {
    const aSeq = normalizeSequence(a.sequence, 0);
    const bSeq = normalizeSequence(b.sequence, 0);

    const aCallId = isToolItem(a) ? toolCallId(a) : null;
    const bCallId = isToolItem(b) ? toolCallId(b) : null;

    const aBase =
      a.type === 'tool_result' && aCallId && callSequenceById.has(aCallId)
        ? (callSequenceById.get(aCallId) as number)
        : aSeq;
    const bBase =
      b.type === 'tool_result' && bCallId && callSequenceById.has(bCallId)
        ? (callSequenceById.get(bCallId) as number)
        : bSeq;

    if (aBase !== bBase) return aBase - bBase;

    const rank = (type: string) => {
      if (type === 'tool_call') return 0;
      if (type === 'tool_result') return 1;
      return 2;
    };

    const rankDiff = rank(a.type) - rank(b.type);
    if (rankDiff !== 0) return rankDiff;

    if (aSeq !== bSeq) return aSeq - bSeq;
    return String(a.type || '').localeCompare(String(b.type || ''));
  });
};

const orderedItemsForStep = (step: ChatMessageStep) => reorderTraceItemsForDisplay(step.items || []);

type ToolRow = { call: ChatMessageItem | null; result: ChatMessageItem | null };

const canPairCallWithResult = (callItem: ChatMessageItem, resultItem: ChatMessageItem) => {
  const callId = toolCallId(callItem);
  const resultId = toolCallId(resultItem);
  if (callId && resultId) return callId === resultId;
  return true;
};

const toolRowsForStep = (items: ChatMessageItem[]): ToolRow[] => {
  const rows: ToolRow[] = [];
  let index = 0;

  while (index < items.length) {
    const current = items[index];
    if (current.type === 'tool_call') {
      const next = items[index + 1];
      if (next && next.type === 'tool_result' && canPairCallWithResult(current, next)) {
        rows.push({ call: current, result: next });
        index += 2;
        continue;
      }
      rows.push({ call: current, result: null });
      index += 1;
      continue;
    }

    if (current.type === 'tool_result') {
      rows.push({ call: null, result: current });
      index += 1;
      continue;
    }

    index += 1;
  }

  return rows;
};

const stepGroups = computed(() => {
  const steps = (props.message.steps || []).slice().sort(sortBySeq);
  return steps.map((step, index) => ({
    key: String(step.id ?? `seq:${step.sequence ?? 0}`),
    sequence: typeof step.sequence === 'number' ? step.sequence : index + 1,
    createdAt: step.created_at || null,
    step,
    normalItems: orderedItemsForStep(step).filter((item) => !isToolItem(item)),
    toolRows: toolRowsForStep(orderedItemsForStep(step).filter(isToolItem)),
  }));
});

const itemText = (item: ChatMessageItem) => joinItemTextContents(item.type, item.contents);
const itemMedia = (item: ChatMessageItem) =>
  (item.contents || []).filter((content) => content.kind === 'media' && content.media);

const renderCache = new Map<string, string>();
const renderHtml = (text: string) => {
  const key = text;
  const cached = renderCache.get(key);
  if (cached != null) return cached;

  const html = renderMessage(text, { highlightCode: true });
  if (renderCache.size > 100) renderCache.clear();
  renderCache.set(key, html);
  return html;
};

const isPrimaryItem = (item: ChatMessageItem) => {
  if (props.message.role === 'user') return item.type === 'input';
  return item.type === 'answer';
};

const itemSummary = (item: ChatMessageItem) => {
  const type = String(item.type || '');
  switch (type) {
    case 'reasoning':
      return 'Reasoning';
    case 'tool_call':
      return 'Tool call';
    case 'tool_result':
      return 'Tool result';
    case 'error':
      return 'Error';
    case 'artifact':
      return 'Artifact';
    case 'other':
      return 'Other';
    default:
      return type ? type : 'Item';
  }
};

const itemKey = (item: ChatMessageItem, stepSequence: number) => {
  return `item:${stepSequence}:${String(item.type || '')}:${Number(item.sequence || 0)}:${toolCallId(item) || ''}`;
};

const toolRowKey = (row: ToolRow, stepSequence: number) => {
  const callKey = row.call ? itemKey(row.call, stepSequence) : 'none';
  const resultKey = row.result ? itemKey(row.result, stepSequence) : 'none';
  return `tool-row:${stepSequence}:${callKey}:${resultKey}`;
};
</script>

<style scoped>
.trace-block {
  width: 100%;
}

.trace-step {
  margin-bottom: 6px;
}

.trace-step-header {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 4px;
  color: #6b7280;
  font-size: 0.82rem;
}

.trace-step-title {
  font-weight: 500;
}

.trace-step-title-button {
  padding: 0;
  font-size: 0.82rem;
}

.trace-step-time {
  white-space: nowrap;
}

.trace-item {
  display: block;
  margin-bottom: 4px;
}

.trace-item-details {
  border: 1px solid #e5e7eb;
  border-radius: 7px;
  background: rgba(255, 255, 255, 0.55);
  padding: 3px 8px;
}

.trace-item-details--tool {
  flex: 1 1 calc((100% - 4px) / 2);
  max-width: calc((100% - 4px) / 2);
  min-width: calc((100% - 4px) / 2);
  background: rgba(255, 255, 255, 0.68);
}

.trace-tool-row {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  gap: 4px;
  margin-bottom: 4px;
}

.trace-item-details--tool[open] {
  flex-basis: 100%;
  max-width: 100%;
  min-width: 100%;
}

.trace-tool-row--single .trace-item-details--tool {
  flex-basis: 100%;
  max-width: 100%;
  min-width: 100%;
}

@media (max-width: 900px) {
  .trace-item-details--tool {
    flex-basis: 100%;
    max-width: 100%;
    min-width: 100%;
  }

  .trace-tool-row {
    flex-direction: column;
  }
}

.trace-item-summary {
  cursor: pointer;
  color: #374151;
  font-size: 0.84rem;
  line-height: 1.2;
}

.trace-item-body {
  margin-top: 4px;
}

.trace-item-more {
  margin-top: 4px;
}

.trace-item-more-link {
  padding: 0;
  font-size: 0.8rem;
}

.muted {
  color: #6b7280;
}
</style>
