<template>
  <div v-if="hasWorking" ref="workingBlockEl" class="working-block" :class="{ 'working-block--open': open }">
    <button
      class="working-toggle"
      type="button"
      @click="emit('toggle')"
      :aria-expanded="open"
      :aria-controls="workingBodyId"
    >
      <span class="working-toggle-title">Working</span>
      <span v-if="lastStepNumber != null && lastStepNumber > 1" class="working-toggle-count">
        ({{ lastStepNumber }})
      </span>
      <span
        v-if="workingElapsedTime"
        class="working-toggle-time"
        title="Working elapsed time"
        aria-label="Working elapsed time"
      >
        · {{ workingElapsedTime }}
      </span>
      <span v-if="loading && !open" class="working-toggle-status" role="status" aria-live="polite">
        Loading…
      </span>
      <span
        v-else-if="!open && error"
        class="working-toggle-status error-text"
        role="status"
        aria-live="polite"
        :title="error"
      >
        Failed to load
      </span>
      <span
        v-else-if="!open && retryStatusLabel"
        class="working-toggle-status working-toggle-status--retry"
        role="status"
        aria-live="polite"
        :title="retryStatusTitle"
      >
        {{ retryStatusLabel }}
      </span>
      <SvgIcon name="chevron-right" size="16" class="working-toggle-chevron" />
    </button>

    <transition name="fade">
      <div v-show="open" class="working-body" :id="workingBodyId" :aria-busy="loading ? 'true' : 'false'">
        <template v-if="currentStep">
          <div class="working-step-bar">
            <div class="working-step-meta">
              <span v-if="!showStepNavigation" class="working-step-label">{{ stepLabel(currentStepNumber) }}</span>
              <span
                v-if="currentStepTime"
                class="working-step-time"
                title="Step duration"
                aria-label="Step duration"
              >
                {{ currentStepTime }}
              </span>
              <button
                v-if="canOpenStep(currentStep)"
                class="working-text-button working-step-details"
                type="button"
                @click.stop.prevent="emit('step-info', currentStep)"
              >
                Details
              </button>
            </div>

            <span v-if="loading" class="working-step-loading" role="status" aria-live="polite">
              Loading…
            </span>

            <div v-if="showStepNavigation" class="working-nav" role="group" aria-label="Step navigation">
              <button
                type="button"
                class="working-nav-button"
                :disabled="loading || !canGoPrev"
                title="First step"
                aria-label="First step"
                @click="goFirst"
              >
                <SvgIcon name="chevrons-left" size="14" />
              </button>
              <button
                type="button"
                class="working-nav-button"
                :disabled="loading || !canGoPrev"
                title="Previous step"
                aria-label="Previous step"
                @click="goPrev"
              >
                <SvgIcon name="chevron-left" size="14" />
              </button>
              <select
                class="working-nav-select"
                :value="currentStepId || ''"
                :disabled="loading"
                @change="onStepSelectChange"
                aria-label="Select step"
              >
                <option v-for="option in stepOptions" :key="option.id" :value="option.id">
                  {{ stepLabel(option.number) }}
                </option>
              </select>
              <button
                type="button"
                class="working-nav-button"
                :disabled="loading || !canGoNext"
                title="Next step"
                aria-label="Next step"
                @click="goNext"
              >
                <SvgIcon name="chevron-right" size="14" />
              </button>
              <button
                type="button"
                class="working-nav-button"
                :disabled="loading || !canGoNext"
                title="Last step"
                aria-label="Last step"
                @click="goLast"
              >
                <SvgIcon name="chevrons-right" size="14" />
              </button>
            </div>
          </div>

          <div v-if="error" class="working-inline-state error-text" role="alert">{{ error }}</div>
          <div
            v-if="showRetryNotice"
            class="working-retry-notice"
            :title="latestRetryErrorText"
          >
            <span class="working-retry-notice__label">{{ translate('Latest transient error') }}</span>
            <span v-if="latestRetryStepSequence != null" class="working-retry-notice__step">
              · {{ translate('Step') }} {{ latestRetryStepSequence }}
            </span>
            <span class="working-retry-notice__text">{{ latestRetryErrorPreview }}</span>
          </div>

          <div v-if="currentTraceEntries.length" class="working-trace">
            <template v-for="entry in currentTraceEntries" :key="entry.key">
              <div
                v-if="entry.kind === 'tool'"
                class="working-item working-item--tool"
                :class="{ 'working-item--pending': isToolGroupPending(entry) }"
              >
                <div class="working-item-header">
                  <SvgIcon name="wrench" size="14" class="working-item-icon" />
                  <span class="working-item-label">{{ itemTitle('tool_call') }}</span>
                  <code class="working-tool-name">{{ toolCallInfo(entry.call).name || 'unknown' }}</code>
                  <span
                    v-if="isToolGroupPending(entry)"
                    class="working-item-status"
                    role="status"
                    aria-live="polite"
                  >
                    {{ translate('Running…') }}
                  </span>
                  <span v-else-if="!entry.results.length" class="working-item-status">
                    {{ translate('No result') }}
                  </span>
                </div>

                <div v-if="toolCallInfo(entry.call).arguments !== null" class="working-item-section working-item-json">
                  <JsonTreeView
                    :value="toolCallInfo(entry.call).arguments"
                    :download-filename="toolCallArgumentsDownloadFilename(entry.call)"
                    preserve-expanded-on-value-change
                  >
                    <template #label>
                      <span class="working-section-label">{{ translate('Arguments') }}</span>
                    </template>
                  </JsonTreeView>
                </div>

                <div
                  v-for="result in entry.results"
                  :key="result.id"
                  class="working-item-section working-tool-result-section"
                >
                  <div class="working-section-label">{{ translate('Result') }}</div>
                  <pre v-if="itemText(result).trim()" class="code-block working-tool-result">{{ itemText(result) }}</pre>
                  <button
                    v-if="canOpenFullText(result)"
                    type="button"
                    class="working-text-button"
                    @click.stop.prevent="openFullText(result)"
                  >
                    {{ translate('Show full text') }}
                  </button>
                  <ChatMediaList
                    v-if="toolItemMedia(result).length"
                    :message-id="props.messageId"
                    :contents="toolItemMedia(result)"
                    @preview="(payload) => emit('attachment-open', payload)"
                  />
                  <div
                    v-if="!itemText(result).trim() && !toolItemMedia(result).length"
                    class="working-empty"
                  >
                    {{ translate('No data') }}
                  </div>
                </div>

                <div
                  v-for="artifact in entry.artifacts"
                  :key="artifact.id"
                  class="working-item-section"
                >
                  <div class="working-section-label">{{ itemTitle('artifact') }}</div>
                  <ChatMediaList
                    v-if="toolItemMedia(artifact).length"
                    :message-id="props.messageId"
                    :contents="toolItemMedia(artifact)"
                    @preview="(payload) => emit('attachment-open', payload)"
                  />
                  <div v-else class="working-empty">{{ translate('No data') }}</div>
                </div>
              </div>

              <div
                v-else-if="isCompactPreviewItem(entry.item)"
                class="working-item working-item--compact"
                :class="`working-item--${entry.item.type}`"
              >
                <SvgIcon :name="itemIcon(entry.item.type)" size="14" class="working-item-icon" />
                <span class="working-item-label working-item-preview-label">{{ itemTitle(entry.item.type) }}</span>
                <span class="working-item-preview-text">
                  {{ compactItemPreview(entry.item) || translate('No data') }}
                </span>
              </div>

              <div v-else class="working-item" :class="`working-item--${entry.item.type}`">
                <div class="working-item-header">
                  <SvgIcon :name="itemIcon(entry.item.type)" size="14" class="working-item-icon" />
                  <span class="working-item-label">{{ itemTitle(entry.item.type) }}</span>
                  <button
                    v-if="canCopyThinking(entry.item)"
                    type="button"
                    class="working-copy-button"
                    :class="{ copied: copiedThinkingItemId === entry.item.id }"
                    :aria-label="copiedThinkingItemId === entry.item.id ? 'Thinking copied' : 'Copy thinking'"
                    :title="copiedThinkingItemId === entry.item.id ? 'Thinking copied' : 'Copy thinking'"
                    @click.stop.prevent="copyThinking(entry.item)"
                  >
                    <SvgIcon :name="copiedThinkingItemId === entry.item.id ? 'check' : 'copy'" size="14" />
                  </button>
                </div>

                <div
                  v-if="entry.item.type === 'reasoning' && itemText(entry.item).trim()"
                  class="working-item-body"
                  v-html="renderHtml(itemText(entry.item))"
                ></div>

                <div v-else-if="entry.item.type === 'tool_result'" class="working-item-body">
                  <pre
                    v-if="itemText(entry.item).trim()"
                    class="code-block working-tool-result"
                  >{{ itemText(entry.item) }}</pre>
                  <button
                    v-if="canOpenFullText(entry.item)"
                    type="button"
                    class="working-text-button"
                    @click.stop.prevent="openFullText(entry.item)"
                  >
                    {{ translate('Show full text') }}
                  </button>
                  <ChatMediaList
                    v-if="toolItemMedia(entry.item).length"
                    :message-id="props.messageId"
                    :contents="toolItemMedia(entry.item)"
                    @preview="(payload) => emit('attachment-open', payload)"
                  />
                </div>

                <div v-else-if="entry.item.type === 'artifact'" class="working-item-body">
                  <ChatMediaList
                    v-if="toolItemMedia(entry.item).length"
                    :message-id="props.messageId"
                    :contents="toolItemMedia(entry.item)"
                    @preview="(payload) => emit('attachment-open', payload)"
                  />
                  <div v-else class="working-empty">No data</div>
                </div>

                <div
                  v-else-if="entry.item.type === 'error' && itemText(entry.item).trim()"
                  class="working-item-body"
                  v-html="renderHtml(itemText(entry.item))"
                ></div>

                <div
                  v-else-if="unknownContentValue(entry.item) !== null"
                  class="working-item-body working-item-json"
                >
                  <JsonTreeView
                    :value="unknownContentValue(entry.item)"
                    :download-filename="unknownContentDownloadFilename(entry.item)"
                    preserve-expanded-on-value-change
                  />
                </div>

                <div v-else class="working-item-body working-empty">No data</div>
              </div>
            </template>
          </div>
        </template>
        <div v-else-if="open && loading" class="working-empty">Loading working details…</div>
        <div v-else-if="open && error" class="error-text">{{ error }}</div>
        <div v-else-if="open" class="working-empty">No working details</div>
      </div>
    </transition>
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, onUpdated, ref, watch } from 'vue';

import ChatMediaList from '@/components/chat/ChatMediaList.vue';
import JsonTreeView from '@/components/chat/JsonTreeView.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { translate } from '@/i18n';
import type {
  ChatMessageContent,
  ChatMessageItem,
  ChatMessageStep,
  ChatMessageWorkingSummary,
} from '@/types/api';
import { joinItemTextContents } from '@/utils/chatItemText';
import { enhanceRenderedChatMessageHtml, renderChatMessageHtml as renderMessage } from '@/utils/chatMarkdown';
import { copyTextWithFallback } from '@/utils/clipboard';

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
const isMessageGenerating = computed(() => props.messageStatus === 'generating');
const retryErrorCount = computed(() => {
  const value = Number(props.summary?.retry_error_count ?? 0);
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
});
const latestRetryErrorText = computed(() => String(props.summary?.latest_retry_error_text || '').trim());
const latestRetryStepSequence = computed(() => {
  const value = Number(props.summary?.latest_retry_error_step_sequence);
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : null;
});
const latestWorkingStepSequence = computed(() => {
  const value = Number(props.summary?.latest_step_sequence);
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : null;
});
const latestWorkingStepStatus = computed(() => String(props.summary?.latest_step_status || ''));
const latestSuccessfulStepSequence = computed(() => {
  const explicitValue = Number(props.summary?.latest_successful_step_sequence);
  if (Number.isFinite(explicitValue) && explicitValue > 0) return Math.floor(explicitValue);
  if (['done', 'waiting_tools'].includes(latestWorkingStepStatus.value)) {
    return latestWorkingStepSequence.value;
  }
  return null;
});
const retryChainResolvedSuccessfully = computed(
  () =>
    latestSuccessfulStepSequence.value != null &&
    latestRetryStepSequence.value != null &&
    latestSuccessfulStepSequence.value > latestRetryStepSequence.value
);
const showProminentRetryDiagnostics = computed(
  () => retryErrorCount.value > 0 && !retryChainResolvedSuccessfully.value
);
const latestRetryErrorPreview = computed(() => firstMeaningfulLine(latestRetryErrorText.value));
const retryStatusLabel = computed(() => {
  const count = retryErrorCount.value;
  if (count <= 0 || !showProminentRetryDiagnostics.value) return '';

  if (isMessageGenerating.value) {
    return count === 1
      ? translate('Retrying after transient error')
      : translate('Retrying after {count} transient errors', { count });
  }

  return count === 1
    ? translate('Transient retry error')
    : translate('{count} transient retry errors', { count });
});
const retryStatusTitle = computed(() => latestRetryErrorText.value || retryStatusLabel.value);
const showRetryNotice = computed(
  () => showProminentRetryDiagnostics.value && latestRetryErrorPreview.value !== ''
);

const nowMs = ref(Date.now());
const workingBlockEl = ref<HTMLElement | null>(null);
const copiedThinkingItemId = ref<number | null>(null);
let nowTimer: number | null = null;
let copiedThinkingTimer: number | null = null;

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

const activeStepStartedAtMs = computed(() => parseIsoMs(props.summary?.active_step_started_at));
const completedWorkingDurationMs = computed(() => {
  const value = Number(props.summary?.completed_step_duration_ms ?? 0);
  return Number.isFinite(value) && value > 0 ? value : 0;
});
const activeWorkingDurationMs = computed(() => {
  if (!isMessageGenerating.value) return 0;
  const startedAt = activeStepStartedAtMs.value;
  if (startedAt == null) return 0;
  return clampDurationMs(nowMs.value - startedAt);
});
const totalWorkingDurationMs = computed(() => {
  if (props.summary?.completed_step_duration_ms == null && activeStepStartedAtMs.value == null) return null;
  return completedWorkingDurationMs.value + activeWorkingDurationMs.value;
});
const workingElapsedTime = computed(() => formatDurationTimer(totalWorkingDurationMs.value));
const currentStepTime = computed(() => {
  const durationMs = currentStepDurationMs(currentStep.value);
  return formatDurationTimer(durationMs);
});
const shouldTick = computed(() => isMessageGenerating.value && activeStepStartedAtMs.value != null);

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

const stepLabel = (number: number | null) =>
  number == null ? translate('Step') : translate('Step {number}', { number });

const itemIcon = (type: string) => {
  if (type === 'reasoning') return 'lightbulb';
  if (type === 'answer') return 'chat';
  if (type === 'steering') return 'user';
  if (type === 'tool_call' || type === 'tool_result') return 'wrench';
  if (type === 'artifact') return 'tool-artifact';
  if (type === 'error') return 'alert';
  return 'document';
};

const itemTitle = (type: string) => {
  if (type === 'reasoning') return translate('Thinking');
  if (type === 'answer') return translate('Answering');
  if (type === 'steering') return translate('Steering');
  if (type === 'tool_call') return translate('Tool call');
  if (type === 'tool_result') return translate('Tool result');
  if (type === 'artifact') return translate('Artifact');
  if (type === 'error') return translate('Error');
  return type || 'Item';
};

const isMessageFinished = computed(
  () => Boolean(props.messageStatus) && props.messageStatus !== 'generating'
);

const parseIsoMs = (iso?: string | null): number | null => {
  if (!iso) return null;
  const timestamp = Date.parse(iso);
  return Number.isFinite(timestamp) ? timestamp : null;
};

const clampDurationMs = (durationMs: number) =>
  Number.isFinite(durationMs) && durationMs > 0 ? Math.floor(durationMs) : 0;

const formatDurationTimer = (durationMs: number | null) => {
  if (durationMs == null) return '';
  const totalSeconds = Math.floor(clampDurationMs(durationMs) / 1000);
  const seconds = totalSeconds % 60;
  const totalMinutes = Math.floor(totalSeconds / 60);
  const minutes = totalMinutes % 60;
  const hours = Math.floor(totalMinutes / 60);
  const pad2 = (value: number) => String(value).padStart(2, '0');

  if (hours > 0) return `${hours}:${pad2(minutes)}:${pad2(seconds)}`;
  return `${totalMinutes}:${pad2(seconds)}`;
};

const firstMeaningfulLine = (value: string) => {
  const text = String(value || '').trim();
  if (!text) return '';
  const line = text
    .split(/\r?\n/u)
    .map((part) => part.trim())
    .find((part) => part !== '');
  return line || text;
};

const isActiveStep = (step: ChatMessageStep) => {
  if (step.finished_at) return false;
  return step.status === 'waiting_provider' || step.status === 'waiting_tools';
};

const currentStepDurationMs = (step: ChatMessageStep | null) => {
  if (!step) return null;

  const startedAt = parseIsoMs(step.created_at);
  if (startedAt == null) return null;

  const finishedAt = parseIsoMs(step.finished_at);
  if (finishedAt != null) return clampDurationMs(finishedAt - startedAt);

  if (isMessageGenerating.value && isActiveStep(step)) {
    return clampDurationMs(nowMs.value - startedAt);
  }

  return null;
};

const stopNowTimer = () => {
  if (nowTimer == null) return;
  window.clearInterval(nowTimer);
  nowTimer = null;
};

const stopCopiedThinkingTimer = () => {
  if (copiedThinkingTimer == null) return;
  window.clearTimeout(copiedThinkingTimer);
  copiedThinkingTimer = null;
};

watch(
  shouldTick,
  (enabled) => {
    if (!enabled) {
      stopNowTimer();
      return;
    }

    nowMs.value = Date.now();
    if (nowTimer != null) return;
    nowTimer = window.setInterval(() => {
      nowMs.value = Date.now();
    }, 1000);
  },
  { immediate: true }
);

onUnmounted(() => {
  stopNowTimer();
  stopCopiedThinkingTimer();
});

const highlightWorkingJsonBlocks = () => {
  const root = workingBlockEl.value;
  if (!root) return;
  void enhanceRenderedChatMessageHtml(root, { highlightCode: true });
};

const scheduleHighlightWorkingJsonBlocks = () => {
  void nextTick(highlightWorkingJsonBlocks);
};

onMounted(scheduleHighlightWorkingJsonBlocks);
onUpdated(scheduleHighlightWorkingJsonBlocks);

const renderCache = new Map<string, string>();
const renderHtml = (text: string) => {
  const highlightCode = isMessageFinished.value;
  const key = `${highlightCode ? '1' : '0'}:${text}`;
  const cached = renderCache.get(key);
  if (cached != null) return cached;

  const html = renderMessage(text, { highlightCode, attachmentLinks: true });
  if (renderCache.size > 100) renderCache.clear();
  renderCache.set(key, html);
  return html;
};

const traceItems = (step: ChatMessageStep) => orderedItems(step).filter((item) => item.type !== 'input');

type WorkingToolGroup = {
  kind: 'tool';
  key: string;
  call: ChatMessageItem;
  results: ChatMessageItem[];
  artifacts: ChatMessageItem[];
};

type WorkingTraceEntry = WorkingToolGroup | { kind: 'item'; key: string; item: ChatMessageItem };

/**
 * Groups every tool call with its results so each result renders right after its call.
 * Artifact items carry no call reference; they are persisted right after the result
 * that produced them, so they join the group of the immediately preceding result.
 */
const buildTraceEntries = (items: ChatMessageItem[]): WorkingTraceEntry[] => {
  const groupsByCallId = new Map<number, WorkingToolGroup>();
  for (const item of items) {
    if (item.type !== 'tool_call' || groupsByCallId.has(item.id)) continue;
    groupsByCallId.set(item.id, { kind: 'tool', key: `tool-${item.id}`, call: item, results: [], artifacts: [] });
  }

  const entries: WorkingTraceEntry[] = [];
  let artifactOwner: WorkingToolGroup | null = null;

  for (const item of items) {
    if (item.type === 'tool_call') {
      const group = groupsByCallId.get(item.id);
      if (group?.call === item) {
        entries.push(group);
        artifactOwner = null;
        continue;
      }
    }

    if (item.type === 'tool_result' && item.tool_call_item_id != null) {
      const group = groupsByCallId.get(item.tool_call_item_id);
      if (group) {
        group.results.push(item);
        artifactOwner = group;
        continue;
      }
    }

    if (item.type === 'artifact' && artifactOwner) {
      artifactOwner.artifacts.push(item);
      continue;
    }

    artifactOwner = null;
    entries.push({ kind: 'item', key: `item-${item.id}`, item });
  }

  return entries;
};

const currentTraceEntries = computed(() =>
  currentStep.value ? buildTraceEntries(traceItems(currentStep.value)) : []
);

const isToolGroupPending = (group: WorkingToolGroup) =>
  group.results.length === 0 &&
  isMessageGenerating.value &&
  currentStep.value != null &&
  isActiveStep(currentStep.value);

const itemText = (item: Pick<ChatMessageItem, 'type' | 'contents'>) =>
  joinItemTextContents(item.type, item.contents);

const compactPreviewTypes = new Set(['answer', 'steering']);
const compactPreviewCharacterLimit = 50;

const isCompactPreviewItem = (item: Pick<ChatMessageItem, 'type'>) => compactPreviewTypes.has(item.type);

const compactItemPreview = (item: Pick<ChatMessageItem, 'type' | 'contents'>) => {
  const text = itemText(item).trim().replace(/\s+/gu, ' ');
  const characters = Array.from(text);
  if (characters.length <= compactPreviewCharacterLimit) return text;
  return `${characters.slice(0, compactPreviewCharacterLimit).join('')}…`;
};

const canCopyThinking = (item: Pick<ChatMessageItem, 'id' | 'type' | 'contents'>) =>
  item.type === 'reasoning' && itemText(item).trim() !== '';

const copyThinking = async (item: Pick<ChatMessageItem, 'id' | 'type' | 'contents'>) => {
  const text = itemText(item);
  if (!text.trim()) return;

  const copied = await copyTextWithFallback(text, { promptLabel: translate('Copy the thinking manually:') });
  if (!copied) return;

  copiedThinkingItemId.value = item.id;
  stopCopiedThinkingTimer();
  copiedThinkingTimer = window.setTimeout(() => {
    copiedThinkingItemId.value = null;
    copiedThinkingTimer = null;
  }, 1200);
};

const toolItemMedia = (item: Pick<ChatMessageItem, 'contents'>) =>
  ((item.contents || []).slice().sort(sortBySequence) as ChatMessageContent[]).filter(
    (content) => content.kind === 'media' && content.media
  );

const unknownContentPayload = (content: ChatMessageContent): unknown | null => {
  if (content.kind === 'opaque' && content.content_json != null) return content.content_json;

  if (content.kind === 'media' && content.media) {
    return {
      kind: content.kind,
      media: content.media,
    };
  }

  const text = String(content.content_text ?? '');
  if (text.trim()) {
    return {
      kind: content.kind,
      content_text: text,
    };
  }

  if (content.content_json != null) {
    return {
      kind: content.kind,
      content_json: content.content_json,
    };
  }

  return null;
};

const unknownContentValue = (item: Pick<ChatMessageItem, 'contents'>): unknown | null => {
  const payloads = ((item.contents || []).slice().sort(sortBySequence) as ChatMessageContent[])
    .map(unknownContentPayload)
    .filter((payload): payload is unknown => payload !== null);

  if (payloads.length === 0) return null;
  if (payloads.length === 1) return payloads[0];
  return payloads;
};

const unknownContentDownloadFilename = (
  item: Pick<ChatMessageItem, 'id' | 'sequence' | 'type'>
) => {
  const type = String(item.type || 'item').replace(/[^a-z0-9_-]+/giu, '-').replace(/^-|-$/gu, '');
  const id = typeof item.id === 'number' && item.id > 0 ? item.id : item.sequence || 'unknown';
  return `${type || 'item'}-${id}-content.json`;
};

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

const toolCallArgumentsDownloadFilename = (item: Pick<ChatMessageItem, 'id' | 'sequence'>) => {
  const id = typeof item.id === 'number' && item.id > 0 ? item.id : item.sequence || 'unknown';
  return `tool-call-${id}-arguments.json`;
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
  --working-label-size: 0.78rem;
  --working-body-size: 0.9rem;
  --working-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', monospace;
  margin-bottom: 8px;
  border: 1px solid var(--color-border-strong);
  border-radius: 10px;
  background: var(--color-surface-muted);
  overflow: hidden;
  width: 100%;
}

.working-toggle {
  width: 100%;
  text-align: left;
  border: none;
  border-radius: 0;
  background: transparent;
  padding: 9px 12px;
  font-weight: 400;
  display: flex;
  align-items: center;
  gap: 6px;
  cursor: pointer;
}

.working-toggle:hover {
  background: var(--color-surface-hover);
}

.working-toggle-title {
  font-weight: 600;
}

.working-toggle-count,
.working-toggle-time {
  color: var(--color-text-muted);
  font-size: 0.85rem;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.working-toggle-status {
  margin-left: auto;
  color: var(--color-text-muted);
  font-size: 0.85rem;
  white-space: nowrap;
}

.working-toggle-status.error-text {
  color: var(--color-danger);
}

.working-toggle-status--retry {
  color: var(--color-warning-text);
}

.working-toggle-chevron {
  margin-left: auto;
  color: var(--color-text-muted);
  transform: rotate(90deg);
  transition: transform 0.15s ease;
}

.working-toggle-status + .working-toggle-chevron {
  margin-left: 0;
}

.working-block--open .working-toggle-chevron {
  transform: rotate(-90deg);
}

.working-body {
  border-top: 1px solid var(--color-border-strong);
  padding: 10px;
}

.working-body > :last-child {
  margin-bottom: 0;
}

.working-step-bar {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 10px;
  font-size: var(--working-label-size);
  color: var(--color-text-muted);
}

.working-nav {
  display: flex;
  align-items: center;
  gap: 4px;
  min-width: 0;
  margin-left: auto;
}

.working-nav-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 28px;
  height: 28px;
  padding: 0;
  border-color: var(--color-border);
  border-radius: 6px;
  background: var(--color-surface);
  color: var(--color-text-muted);
}

.working-nav-button:hover:not(:disabled) {
  background: var(--color-surface-hover);
  color: var(--color-text);
}

.working-nav-select {
  height: 28px;
  min-width: 96px;
  padding: 0 6px;
  border-color: var(--color-border);
  font-size: var(--working-label-size);
  font-variant-numeric: tabular-nums;
}

.working-step-label {
  font-weight: 600;
}

.working-step-loading {
  margin-left: auto;
  white-space: nowrap;
}

.working-step-loading + .working-nav {
  margin-left: 0;
}

.working-step-meta {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: 28px;
}

.working-step-time {
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.working-text-button {
  padding: 0;
  border: none;
  background: transparent;
  color: var(--color-link);
  font-size: var(--working-label-size);
  line-height: 1.4;
}

.working-text-button:hover {
  background: transparent;
  text-decoration: underline;
}

.working-inline-state {
  margin-bottom: 10px;
  font-size: 0.85rem;
}

.working-retry-notice {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
  margin-bottom: 10px;
  padding: 7px 9px;
  border: 1px solid var(--color-warning-border);
  border-radius: 8px;
  background: var(--color-warning-bg);
  color: var(--color-warning-text);
  font-size: 0.85rem;
  line-height: 1.35;
}

.working-retry-notice__label {
  font-weight: 600;
  white-space: nowrap;
}

.working-retry-notice__step {
  color: var(--color-text-muted);
  white-space: nowrap;
}

.working-retry-notice__text {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.working-trace {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.working-item {
  min-width: 0;
  border: 1px solid color-mix(in srgb, var(--color-border) 50%, var(--color-border-strong));
  border-radius: 8px;
  background: var(--color-surface);
  font-size: var(--working-body-size);
}

.working-item-header {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
  min-height: 32px;
  padding: 4px 6px 4px 10px;
}

.working-item-icon {
  color: var(--color-text-subtle);
}

.working-item-label,
.working-section-label {
  flex: none;
  color: var(--color-text-muted);
  font-size: var(--working-label-size);
  font-weight: 600;
  line-height: 1.4;
}

.working-section-label {
  margin-bottom: 6px;
}

.json-viewer-toolbar-left > .working-section-label {
  margin-bottom: 0;
}

.working-item-body {
  padding: 0 10px 10px;
  overflow-wrap: anywhere;
}

.working-item-body > :deep(:first-child) {
  margin-top: 0;
}

.working-item-body > :deep(:last-child) {
  margin-bottom: 0;
}

.working-item-body :deep(p),
.working-item-body :deep(ul),
.working-item-body :deep(ol) {
  margin: 0 0 6px;
}

.working-item--compact {
  display: flex;
  align-items: center;
  gap: 6px;
  min-height: 32px;
  padding: 4px 10px;
}

.working-item-preview-text {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.working-item--steering .working-item-preview-text {
  color: var(--color-text-muted);
}

.working-item--tool .working-item-header {
  flex-wrap: wrap;
  row-gap: 2px;
}

.working-item-header .working-tool-name {
  min-width: 0;
  overflow-wrap: anywhere;
  padding: 1px 6px;
  border-radius: 4px;
  background: var(--color-surface-hover);
  color: var(--color-text);
  font-family: var(--working-mono);
  font-size: 0.8rem;
}

.working-item-status {
  flex: none;
  margin-left: auto;
  padding-right: 4px;
  color: var(--color-text-muted);
  font-size: var(--working-label-size);
  white-space: nowrap;
}

.working-item--pending .working-item-status {
  color: var(--color-info-text);
}

.working-item-section {
  padding: 8px 10px 10px;
  border-top: 1px solid var(--color-border);
}

.working-tool-result-section {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 6px;
}

.working-tool-result-section > .code-block,
.working-tool-result-section > :deep(.chat-media-list) {
  align-self: stretch;
}

.working-item--error {
  border-color: var(--color-danger-border);
  background: var(--color-danger-bg);
}

.working-item--error .working-item-icon,
.working-item--error .working-item-label,
.working-item--error .working-item-body {
  color: var(--color-danger-text);
}

.working-copy-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 26px;
  height: 26px;
  margin-left: auto;
  padding: 0;
  border-color: transparent;
  border-radius: 6px;
  background: transparent;
  color: var(--color-text-muted);
  line-height: 1;
}

.working-copy-button:hover {
  background: var(--color-surface-hover);
  color: var(--color-text);
}

.working-copy-button.copied {
  border-color: transparent;
  background: transparent;
  color: var(--color-success);
}

.working-item-json {
  width: 100%;
  box-sizing: border-box;
}

.working-item-json :deep(.json-viewer-summary),
.working-item-json :deep(.json-viewer-download) {
  color: var(--color-text-subtle);
  font-size: var(--working-label-size);
}

.working-item-json :deep(.json-viewer-download:hover) {
  color: var(--color-text);
}

.working-item-json :deep(.json-viewer-toolbar-left) {
  gap: 8px;
}

.working-item-json :deep(.json-viewer-toggle) {
  padding: 2px 8px;
  font-size: 0.75rem;
}

.working-item-json :deep(.json-viewer-body) {
  max-height: 32vh;
}

.working-item-json :deep(.json-viewer-raw) {
  max-height: 22vh;
}

.working-item :deep(.code-block) {
  border-radius: 6px;
  font-family: var(--working-mono);
  font-size: 0.78rem;
  line-height: 1.45;
}

.working-tool-result {
  max-height: 240px;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-word;
}

.working-empty {
  color: var(--color-text-muted);
  font-size: var(--working-body-size);
}

@media (max-width: 720px) {
  .working-step-bar {
    flex-wrap: wrap;
  }
}
</style>
