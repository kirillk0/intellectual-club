<template>
  <div v-if="hasWorking" class="working-block">
    <button
      class="working-toggle"
      type="button"
      @click="emit('toggle')"
      :aria-expanded="open"
      :aria-controls="workingBodyId"
    >
      Working<span v-if="lastStepNumber != null && lastStepNumber > 1" class="working-toggle-count">
        ({{ lastStepNumber }})
      </span>
      <span class="chevron">{{ open ? '▲' : '▼' }}</span>
    </button>

    <transition name="fade">
      <div v-show="open" class="working-body" :id="workingBodyId">
        <div v-if="loading" class="working-item-body muted">Loading working details…</div>
        <div v-else-if="error" class="working-item-body error-text">{{ error }}</div>
        <template v-else-if="currentStep">
          <div v-if="showStepNavigation" class="working-nav">
            <div class="working-nav-buttons" role="group" aria-label="Step navigation">
              <button type="button" class="link" :disabled="!canGoPrev" @click="goFirst">
                &lt;&lt; first
              </button>
              <button type="button" class="link" :disabled="!canGoPrev" @click="goPrev">
                &lt; previous
              </button>
              <button type="button" class="link" :disabled="!canGoNext" @click="goNext">
                next &gt;
              </button>
              <button type="button" class="link" :disabled="!canGoNext" @click="goLast">
                last &gt;&gt;
              </button>
            </div>
            <label class="working-nav-select-wrap">
              <span class="working-nav-select-label">Step</span>
              <select
                class="working-nav-select"
                :value="currentStepId || ''"
                @change="onStepSelectChange"
                aria-label="Select step"
              >
                <option v-for="option in stepOptions" :key="option.id" :value="option.id">
                  Step {{ option.number }}
                </option>
              </select>
            </label>
          </div>

          <div class="working-step">
            <div class="working-step-links">
              <button
                v-if="canOpenStep(currentStep)"
                class="link working-step-number working-step-number-button"
                type="button"
                @click.stop.prevent="emit('step-info', currentStep)"
              >
                Step {{ currentStepNumber }}
              </button>
              <span v-else class="working-step-number">Step {{ currentStepNumber }}</span>
              <span v-if="currentStepTime" class="working-step-time">{{ currentStepTime }}</span>
            </div>

            <div v-for="item in providerItems(currentStep)" :key="item.id" class="working-item">
              <div class="working-item-title">{{ itemTitle(item.type) }}</div>

              <div
                v-if="item.type === 'reasoning' && itemText(item).trim()"
                class="working-item-body"
                v-html="renderHtml(itemText(item))"
              ></div>

              <div v-else-if="item.type === 'tool_call'" class="working-item-body">
                <div class="muted" style="margin-bottom: 6px">
                  Calling <code>{{ toolCallInfo(item).name || 'unknown' }}</code>
                </div>
                <div v-if="toolCallInfo(item).arguments !== null">
                  <div class="muted" style="margin-bottom: 4px">Arguments</div>
                  <pre class="code-block" style="white-space: pre-wrap; word-break: break-word">{{
                    formatJson(toolCallInfo(item).arguments)
                  }}</pre>
                </div>
              </div>

              <div
                v-else-if="item.type === 'error' && itemText(item).trim()"
                class="working-item-body"
              >
                <div class="error-text" v-html="renderHtml(itemText(item))"></div>
              </div>

              <div v-else class="working-item-body muted">No data</div>
            </div>

            <template v-if="isStepClosed(currentStep) && toolResultItems(currentStep).length">
              <div class="working-step-sep"></div>
            </template>

            <template v-if="isStepClosed(currentStep) && toolResultItems(currentStep).length">
              <div v-for="item in toolResultItems(currentStep)" :key="item.id" class="working-item">
                <div class="working-item-title">{{ itemTitle(item.type) }}</div>
                <div class="working-item-body">
                  <div v-if="itemText(item).trim()">
                    <pre class="code-block working-tool-result">{{ itemText(item) }}</pre>
                    <button
                      v-if="canOpenFullText(item)"
                      type="button"
                      class="link"
                      @click.stop.prevent="openFullText(item)"
                    >
                      more
                    </button>
                  </div>
                  <ChatMediaList
                    v-if="toolItemMedia(item).length"
                    :message-id="props.messageId"
                    :contents="toolItemMedia(item)"
                    @preview="(payload) => emit('attachment-open', payload)"
                  />
                </div>
              </div>

              <div v-for="item in artifactItems(currentStep)" :key="item.id" class="working-item">
                <div class="working-item-title">{{ itemTitle(item.type) }}</div>
                <div class="working-item-body">
                  <ChatMediaList
                    v-if="toolItemMedia(item).length"
                    :message-id="props.messageId"
                    :contents="toolItemMedia(item)"
                    @preview="(payload) => emit('attachment-open', payload)"
                  />
                  <div v-else class="muted">No data</div>
                </div>
              </div>

              <div class="working-step-sep"></div>
            </template>
          </div>
        </template>
        <div v-else class="working-item-body muted">No working details</div>
      </div>
    </transition>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import ChatMediaList from '@/components/chat/ChatMediaList.vue';
import type {
  ChatMessageContent,
  ChatMessageItem,
  ChatMessageStep,
  ChatMessageWorkingSummary,
} from '@/types/api';
import { joinItemTextContents } from '@/utils/chatItemText';
import { renderChatMessageHtml as renderMessage } from '@/utils/chatMarkdown';
import { displayTimestampIso, formatTimeOfDay } from '@/utils/dates';

interface Props {
  messageId: number | null;
  messageStatus?: 'generating' | 'canceled' | 'error' | 'done' | string | null;
  summary?: ChatMessageWorkingSummary | null;
  stepIndex?: ChatMessageStep[] | null;
  selectedStep?: ChatMessageStep | null;
  loading?: boolean;
  error?: string;
  open?: boolean;
}

const props = withDefaults(defineProps<Props>(), {
  messageId: null,
  messageStatus: null,
  summary: null,
  stepIndex: () => [],
  selectedStep: null,
  loading: false,
  error: '',
  open: false,
});

const emit = defineEmits<{
  (e: 'toggle'): void;
  (e: 'step-select', stepId: number): void;
  (e: 'step-info', step: ChatMessageStep): void;
  (e: 'content-open', payload: { messageId: number; contentId: number; title: string }): void;
  (e: 'attachment-open', payload: { messageId: number; content: ChatMessageContent }): void;
}>();

const sortBySequence = <T extends { sequence?: number | null }>(a: T, b: T) => {
  const aSeq = typeof a.sequence === 'number' && Number.isFinite(a.sequence) ? a.sequence : 0;
  const bSeq = typeof b.sequence === 'number' && Number.isFinite(b.sequence) ? b.sequence : 0;
  return aSeq - bSeq;
};

const orderedItems = (step: ChatMessageStep | null | undefined): ChatMessageItem[] =>
  ((step?.items || []).slice().sort(sortBySequence) as ChatMessageItem[]);

const steps = computed(() => (props.stepIndex || []).slice().sort(sortBySequence));
const open = computed(() => Boolean(props.open));
const loading = computed(() => Boolean(props.loading));
const error = computed(() => props.error || '');

const hasWorking = computed(() => {
  if (!props.messageId) return false;
  return (props.summary?.step_count || 0) > 0 || steps.value.length > 0 || Boolean(props.selectedStep);
});

const lastStepNumber = computed<number | null>(() => {
  if (typeof props.summary?.latest_step_sequence === 'number') return props.summary.latest_step_sequence;
  if (typeof props.summary?.step_count === 'number' && props.summary.step_count > 0) return props.summary.step_count;
  if (!steps.value.length) return null;
  const sequences = steps.value
    .map((s) => (typeof s.sequence === 'number' ? s.sequence : null))
    .filter((v): v is number => typeof v === 'number');
  if (!sequences.length) return steps.value.length;
  return Math.max(...sequences);
});

const workingBodyId = computed(() => (props.messageId ? `working-${props.messageId}` : undefined));
const showStepNavigation = computed(() => steps.value.length > 1);
const currentStep = computed(() => props.selectedStep || null);
const currentStepId = computed(() => currentStep.value?.id ?? null);
const currentStepIndex = computed(() => {
  const id = currentStepId.value;
  const index = steps.value.findIndex((step) => step.id === id);
  if (index >= 0) return index;
  return steps.value.length ? steps.value.length - 1 : 0;
});
const currentStepNumber = computed(() => {
  if (!currentStep.value) return null;
  return stepNumber(currentStep.value, currentStepIndex.value);
});
const currentStepTime = computed(() => formatTimeOfDay(displayTimestampIso(currentStep.value)));

const stepOptions = computed(() =>
  steps.value.map((step, index) => ({
    id: step.id,
    number: stepNumber(step, index),
  }))
);

const canGoPrev = computed(() => currentStepIndex.value > 0);
const canGoNext = computed(() => currentStepIndex.value < steps.value.length - 1);

const selectStepAt = (index: number) => {
  const step = steps.value[index];
  if (!step?.id) return;
  emit('step-select', step.id);
};

const goFirst = () => {
  selectStepAt(0);
};

const goPrev = () => {
  if (!canGoPrev.value) return;
  selectStepAt(currentStepIndex.value - 1);
};

const goNext = () => {
  if (!canGoNext.value) return;
  selectStepAt(currentStepIndex.value + 1);
};

const goLast = () => {
  if (!steps.value.length) return;
  selectStepAt(steps.value.length - 1);
};

const onStepSelectChange = (event: Event) => {
  const target = event.target as HTMLSelectElement;
  const stepId = Number(target.value);
  if (!Number.isFinite(stepId) || stepId <= 0) return;
  emit('step-select', stepId);
};

const canOpenStep = (step: ChatMessageStep | null) => Boolean(step && typeof step.id === 'number' && step.id > 0);

const stepNumber = (step: ChatMessageStep, index: number) => {
  if (typeof step.sequence === 'number') return step.sequence;
  return index + 1;
};

const itemTitle = (type: string) => {
  if (type === 'reasoning') return 'Thinking';
  if (type === 'answer') return 'Answering';
  if (type === 'tool_call') return 'Tool call';
  if (type === 'tool_result') return 'Tool result';
  if (type === 'error') return 'Error';
  return type || 'Item';
};

const isResponseFinal = (step: ChatMessageStep) => Boolean(step.response_final);
const isMessageFinished = computed(
  () => Boolean(props.messageStatus) && props.messageStatus !== 'generating'
);
const isStepClosed = (step: ChatMessageStep) => isResponseFinal(step) || isMessageFinished.value;

const renderCache = new Map<string, string>();
const renderHtml = (text: string) => {
  const highlightCode = isMessageFinished.value;
  const key = `${highlightCode ? '1' : '0'}:${text}`;
  const cached = renderCache.get(key);
  if (cached != null) return cached;

  const html = renderMessage(text, { highlightCode });
  if (renderCache.size > 100) renderCache.clear();
  renderCache.set(key, html);
  return html;
};

const providerItems = (step: ChatMessageStep) => {
  const list = orderedItems(step);
  return list.filter(
    (item) =>
      item.type !== 'tool_result' &&
      item.type !== 'artifact' &&
      item.type !== 'answer' &&
      item.type !== 'input'
  );
};

const toolResultItems = (step: ChatMessageStep) => {
  const list = orderedItems(step);
  return list.filter((item) => item.type === 'tool_result');
};

const artifactItems = (step: ChatMessageStep) => {
  const list = orderedItems(step);
  return list.filter((item) => item.type === 'artifact');
};

const itemText = (item: Pick<ChatMessageItem, 'type' | 'contents'>) =>
  joinItemTextContents(item.type, item.contents);

const toolItemMedia = (item: Pick<ChatMessageItem, 'contents'>) =>
  ((item.contents || []).slice().sort(sortBySequence) as ChatMessageContent[]).filter(
    (content) => content.kind === 'media' && content.media
  );

const firstTruncatedTextContentId = (item: ChatMessageItem): number | null => {
  const contents = (item.contents || []).slice().sort(sortBySequence);
  for (const content of contents) {
    if (content.kind !== 'text') continue;
    if (!content.content_text_truncated) continue;
    if (typeof content.id === 'number' && content.id > 0) return content.id;
  }
  return null;
};

const canOpenFullText = (item: ChatMessageItem) => {
  if (item.type !== 'tool_result') return false;
  if (props.messageId == null) return false;
  return firstTruncatedTextContentId(item) != null;
};

const openFullText = (item: ChatMessageItem) => {
  if (props.messageId == null) return;
  const contentId = firstTruncatedTextContentId(item);
  if (contentId == null) return;
  emit('content-open', { messageId: props.messageId, contentId, title: 'Tool result full text' });
};

const formatJson = (value: unknown) => {
  try {
    return JSON.stringify(value ?? null, null, 2);
  } catch {
    return String(value);
  }
};

const asRecord = (value: unknown): Record<string, unknown> | null => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
};

const firstOpaqueJson = (contents: ChatMessageContent[] | undefined | null) => {
  const list = contents || [];
  const hit = list.find((c) => c && c.kind === 'opaque' && c.content_json != null);
  return hit ? (hit.content_json as unknown) : null;
};

const toolCallInfo = (item: Pick<ChatMessageItem, 'contents'>) => {
  const raw = firstOpaqueJson(item.contents);
  const rec = asRecord(raw);
  if (!rec) return { name: '', arguments: null as unknown, raw: raw ?? null };
  const rawTool = asRecord(rec.raw);
  const rawFunction = asRecord(rawTool?.function);
  const name =
    typeof rec.name === 'string'
      ? rec.name
      : typeof rawFunction?.name === 'string'
        ? rawFunction.name
        : typeof rawTool?.name === 'string'
          ? rawTool.name
          : '';
  const argsSource = rec.arguments ?? rawFunction?.arguments ?? rawTool?.arguments ?? null;
  return { name, arguments: normalizeToolCallArguments(argsSource), raw: rawTool ?? raw };
};

const normalizeToolCallArguments = (value: unknown): unknown | null => {
  if (value == null) return null;
  if (typeof value !== 'string') return value;

  const text = value.trim();
  if (!text) return {};

  try {
    return JSON.parse(text);
  } catch {
    return value;
  }
};
</script>

<style scoped>
.working-block {
  margin-bottom: 8px;
  border: 1px solid #d0d7de;
  border-radius: 8px;
  background: #f2f4f8;
  overflow: hidden;
  width: 100%;
}

.working-toggle {
  width: 100%;
  text-align: left;
  border: none;
  background: #f2f4f8;
  padding: 10px 12px;
  font-weight: 400;
  display: flex;
  align-items: center;
  gap: 6px;
  cursor: pointer;
}

.working-toggle .chevron {
  margin-left: auto;
  font-size: 0.9em;
}

.working-toggle-count {
  color: #6b7280;
}

.working-body {
  border-top: 1px solid #d0d7de;
  padding: 10px 12px;
  background: #f2f4f8;
}

.working-nav {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 10px;
}

.working-nav-buttons {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

.working-nav-select-wrap {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 0.85rem;
  color: #6b7280;
}

.working-nav-select-label {
  white-space: nowrap;
}

.working-nav-select {
  min-width: 108px;
}

.working-step {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.working-step-number {
  font-size: 0.78rem;
  color: #6b7280;
}

.working-step-time {
  margin-left: auto;
  font-size: 0.78rem;
  color: #6b7280;
  font-variant-numeric: tabular-nums;
}

.working-item-title {
  font-size: 0.78rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: #6b7280;
  margin-bottom: 4px;
}

.working-item-body {
  font-size: 0.95em;
}

.working-tool-result {
  max-height: 240px;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-word;
}

.working-step-footer {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: 8px;
  margin-top: 2px;
}

.working-step-links {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 0.95em;
  width: 100%;
}

.working-step-links-secondary {
  margin-top: 4px;
}

.working-step-links-spacer {
  margin-left: auto;
}

.working-step-sep {
  height: 1px;
  width: 100%;
  background: #d0d7de;
}

.info-link {
  padding: 0;
}

@media (max-width: 720px) {
  .working-nav {
    flex-direction: column;
    align-items: stretch;
  }

  .working-nav-select-wrap {
    justify-content: space-between;
  }
}
</style>
