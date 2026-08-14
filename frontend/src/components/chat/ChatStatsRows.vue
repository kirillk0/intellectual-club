<template>
  <div class="chat-stats-rows">
    <div class="chat-stats-token-group">
      <div class="chat-stats-row chat-stats-row--total">
        <span class="chat-stats-label">{{ translate('Input tokens (total)') }}</span>
        <span>{{ formatMetric(stats?.input_tokens) }}</span>
      </div>
      <div class="chat-stats-breakdown" :aria-label="translate('Input token breakdown')">
        <div class="chat-stats-row chat-stats-row--part">
          <span class="chat-stats-label">{{ translate('Cold input tokens') }}</span>
          <span>{{ formatMetric(coldInputTokens) }}</span>
        </div>
        <div class="chat-stats-row chat-stats-row--part">
          <span class="chat-stats-label">{{ translate('Cached input tokens') }}</span>
          <span>{{ formatMetric(stats?.cached_input_tokens) }}</span>
        </div>
      </div>
    </div>

    <div class="chat-stats-token-group">
      <div class="chat-stats-row chat-stats-row--total">
        <span class="chat-stats-label">{{ translate('Output tokens (total, incl. reasoning)') }}</span>
        <span>{{ formatMetric(stats?.output_tokens) }}</span>
      </div>
      <div class="chat-stats-breakdown" :aria-label="translate('Output token breakdown')">
        <div class="chat-stats-row chat-stats-row--part">
          <span class="chat-stats-label">{{ translate('Non-reasoning output tokens') }}</span>
          <span>{{ formatMetric(nonReasoningOutputTokens) }}</span>
        </div>
        <div class="chat-stats-row chat-stats-row--part">
          <span class="chat-stats-label">{{ translate('Reasoning tokens') }}</span>
          <span>{{ formatMetric(stats?.reasoning_tokens) }}</span>
        </div>
      </div>
    </div>

    <div class="chat-stats-row">
      <span class="chat-stats-label">{{ translate('Time to first token') }}</span>
      <span>{{ formatDurationMs(stats?.time_to_first_token_ms) }}</span>
    </div>
    <div class="chat-stats-row">
      <span class="chat-stats-label">{{ translate('Output speed (TPS)') }}</span>
      <span>{{ formatTokensPerSecond(stats?.tokens_per_second) }}</span>
    </div>
    <div class="chat-stats-row">
      <span class="chat-stats-label">{{ translate('Cost (USD)') }}</span>
      <span>{{ formatCost(stats?.cost) }}</span>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import { translate } from '@/i18n';
import type { ChatUsageStats } from '@/types/api';
import {
  formatStepCost as formatCost,
  formatStepDurationMs as formatDurationMs,
  formatStepMetric as formatMetric,
  formatTokensPerSecond,
  subtractIncludedTokens,
} from '@/utils/stepStats';

interface Props {
  stats: ChatUsageStats | null | undefined;
}

const props = defineProps<Props>();

const coldInputTokens = computed(() =>
  subtractIncludedTokens(props.stats?.input_tokens, props.stats?.cached_input_tokens)
);
const nonReasoningOutputTokens = computed(() =>
  subtractIncludedTokens(props.stats?.output_tokens, props.stats?.reasoning_tokens)
);
</script>

<style scoped>
.chat-stats-token-group {
  border-bottom: 1px solid var(--color-border);
  padding: 7px 0;
}

.chat-stats-row {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  font-size: 0.95em;
  padding: 6px 0;
  border-bottom: 1px solid var(--color-border);
}

.chat-stats-token-group .chat-stats-row,
.chat-stats-row:last-child {
  border-bottom: none;
}

.chat-stats-row--total {
  font-weight: 600;
  padding-top: 0;
}

.chat-stats-breakdown {
  border-left: 2px solid var(--color-border-strong);
  margin-left: 4px;
  padding-left: 12px;
}

.chat-stats-row--part {
  font-size: 0.88em;
  padding: 3px 0;
}

.chat-stats-label {
  color: var(--color-text-muted);
}

.chat-stats-row--total .chat-stats-label {
  color: var(--color-text);
}
</style>
