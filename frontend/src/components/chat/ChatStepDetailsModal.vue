<template>
  <ModalWindow
    :open="open"
    modal-class="step-details-modal"
    :aria-label="`Step ${stepLabel} details`"
    @cancel="emit('close')"
  >
    <h3 style="margin: 0">Step {{ stepLabel }}</h3>

    <div class="step-tabs" role="tablist" aria-label="Step details tabs">
      <button
        v-for="tab in tabs"
        :key="tab.id"
        class="step-tab"
        :class="{ active: activeTab === tab.id }"
        type="button"
        role="tab"
        :aria-selected="activeTab === tab.id"
        @click="activeTab = tab.id"
      >
        {{ tab.label }}
      </button>
    </div>

    <div class="step-panel">
      <template v-if="activeTab === 'billing'">
        <div class="step-info-row">
          <span class="step-info-label">Input tokens</span>
          <span>{{ formatMetric(step?.input_tokens) }}</span>
        </div>
        <div class="step-info-row">
          <span class="step-info-label">Cached input tokens</span>
          <span>{{ formatMetric(step?.cached_input_tokens) }}</span>
        </div>
        <div class="step-info-row">
          <span class="step-info-label">Output tokens</span>
          <span>{{ formatMetric(step?.output_tokens) }}</span>
        </div>
        <div class="step-info-row">
          <span class="step-info-label">Reasoning tokens</span>
          <span>{{ formatMetric(step?.reasoning_tokens) }}</span>
        </div>
        <div class="step-info-row">
          <span class="step-info-label">Time to first token</span>
          <span>{{ formatDurationMs(step?.time_to_first_token_ms) }}</span>
        </div>
        <div class="step-info-row">
          <span class="step-info-label">Output speed (TPS)</span>
          <span>{{ formatTokensPerSecond(step?.tokens_per_second) }}</span>
        </div>
        <div class="step-info-row">
          <span class="step-info-label">Cost (USD)</span>
          <span>{{ formatCost(step?.cost) }}</span>
        </div>
      </template>

      <template v-else-if="activeTab === 'request'">
        <div v-if="requestLoading" class="muted">Loading payload…</div>
        <div v-else-if="requestErrorText" class="error-text">{{ requestErrorText }}</div>
        <JsonTreeView
          v-else
          class="step-payload"
          :value="requestPayloadValue"
          :download-filename="requestDownloadFilename"
        />
      </template>

      <template v-else-if="activeTab === 'response'">
        <div v-if="responseLoading" class="muted">Loading payload…</div>
        <div v-else-if="responseErrorText" class="error-text">{{ responseErrorText }}</div>
        <JsonTreeView
          v-else
          class="step-payload"
          :value="responsePayloadValue"
          :download-filename="responseDownloadFilename"
        />
      </template>

      <template v-else>
        <div class="step-actions-panel">
          <p v-if="showGeneratingNote" class="muted step-actions-note">
            Retry from this step is available after generation stops.
          </p>
          <button
            v-else
            type="button"
            class="link step-actions-link"
            :disabled="!canRetryFromStep || retryFromStepPending"
            @click="emit('retry-from-step')"
          >
            {{ retryFromStepPending ? 'Retrying…' : 'Retry from this step' }}
          </button>
          <p v-if="showUnavailableNote" class="muted step-actions-note">Step is not available.</p>
        </div>
      </template>
    </div>

    <div class="modal-actions">
      <div class="spacer"></div>
      <button type="button" @click="emit('close')">Close</button>
    </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';

import ModalWindow from '@/components/ModalWindow.vue';
import JsonTreeView from '@/components/chat/JsonTreeView.vue';
import type { ChatMessageStep } from '@/types/api';
import {
  formatStepCost as formatCost,
  formatStepDurationMs as formatDurationMs,
  formatStepMetric as formatMetric,
  formatTokensPerSecond,
} from '@/utils/stepStats';

interface Props {
  open: boolean;
  step: ChatMessageStep | null;
  messageId?: number | null;
  messageStatus?: string | null;
  showBilling?: boolean;
  showResponse?: boolean;
  requestLoading?: boolean;
  requestError?: string;
  requestPayload?: unknown;
  responseLoading?: boolean;
  responseError?: string;
  responsePayload?: unknown;
  retryFromStepPending?: boolean;
}

type TabKey = 'billing' | 'request' | 'response' | 'actions';

const props = withDefaults(defineProps<Props>(), {
  messageId: null,
  messageStatus: null,
  showBilling: false,
  showResponse: false,
  requestLoading: false,
  requestError: '',
  requestPayload: null,
  responseLoading: false,
  responseError: '',
  responsePayload: null,
  retryFromStepPending: false,
});

const emit = defineEmits<{
  (e: 'close'): void;
  (e: 'retry-from-step'): void;
}>();

const tabs = computed<Array<{ id: TabKey; label: string }>>(() => {
  const list: Array<{ id: TabKey; label: string }> = [];
  if (props.showBilling) list.push({ id: 'billing', label: 'Stats' });
  list.push({ id: 'request', label: 'Raw request' });
  if (props.showResponse) list.push({ id: 'response', label: 'Raw response' });
  list.push({ id: 'actions', label: 'Actions' });
  return list;
});

const preferredTab = computed<TabKey>(() => (props.showBilling ? 'billing' : 'request'));
const activeTab = ref<TabKey>('request');

watch(
  () => [props.open, props.showBilling, props.showResponse],
  () => {
    const ids = new Set(tabs.value.map((tab) => tab.id));
    if (!props.open) return;
    if (ids.has(preferredTab.value)) {
      activeTab.value = preferredTab.value;
      return;
    }
    if (!ids.has(activeTab.value)) {
      activeTab.value = tabs.value[0]?.id || 'request';
    }
  },
  { immediate: true }
);

const stepLabel = computed(() => {
  const seq = props.step?.sequence;
  if (typeof seq === 'number' && Number.isFinite(seq) && seq > 0) return String(seq);
  return '—';
});

const requestLoading = computed(() => Boolean(props.requestLoading));
const requestErrorText = computed(() => (props.requestError || '').trim());
const requestPayloadValue = computed(() => props.requestPayload ?? null);

const responseLoading = computed(() => Boolean(props.responseLoading));
const responseErrorText = computed(() => (props.responseError || '').trim());
const responsePayloadValue = computed(() => props.responsePayload ?? null);

const requestDownloadFilename = computed(() => `step-${stepLabel.value}-raw-request.json`);
const responseDownloadFilename = computed(() => `step-${stepLabel.value}-raw-response.json`);
const retryFromStepPending = computed(() => Boolean(props.retryFromStepPending));
const canRetryFromStep = computed(() => Number(props.messageId || 0) > 0 && Number(props.step?.id || 0) > 0);
const showGeneratingNote = computed(() => props.messageStatus === 'generating');
const showUnavailableNote = computed(() => !showGeneratingNote.value && !canRetryFromStep.value);

</script>

<style scoped>
:global(.step-details-modal) {
  max-width: 980px;
}

.step-tabs {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 10px;
}

.step-tab {
  border: 1px solid #d1d5db;
  border-radius: 8px;
  background: #f8fafc;
  color: #334155;
  padding: 5px 10px;
  font-size: 0.88rem;
  line-height: 1.2;
  cursor: pointer;
}

.step-tab.active {
  background: #ffffff;
  border-color: #94a3b8;
  color: #111827;
}

.step-panel {
  margin-top: 10px;
}

.step-actions-panel {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 10px;
  padding: 4px 0;
}

.step-actions-link {
  padding: 0;
}

.step-actions-note {
  margin: 0;
}

.step-info-row {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  font-size: 0.95em;
  padding: 6px 0;
  border-bottom: 1px solid #f1f5f9;
}

.step-info-row:last-child {
  border-bottom: none;
}

.step-info-label {
  color: #64748b;
}

.step-payload {
  margin-top: 2px;
}
</style>
