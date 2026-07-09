<template>
  <div class="chat-stats-rows">
    <div class="chat-stats-row">
      <span class="chat-stats-label">Input tokens</span>
      <span>{{ formatMetric(stats?.input_tokens) }}</span>
    </div>
    <div class="chat-stats-row">
      <span class="chat-stats-label">Cached input tokens</span>
      <span>{{ formatMetric(stats?.cached_input_tokens) }}</span>
    </div>
    <div class="chat-stats-row">
      <span class="chat-stats-label">Output tokens</span>
      <span>{{ formatMetric(stats?.output_tokens) }}</span>
    </div>
    <div class="chat-stats-row">
      <span class="chat-stats-label">Reasoning tokens</span>
      <span>{{ formatMetric(stats?.reasoning_tokens) }}</span>
    </div>
    <div class="chat-stats-row">
      <span class="chat-stats-label">Time to first token</span>
      <span>{{ formatDurationMs(stats?.time_to_first_token_ms) }}</span>
    </div>
    <div class="chat-stats-row">
      <span class="chat-stats-label">Output speed (TPS)</span>
      <span>{{ formatTokensPerSecond(stats?.tokens_per_second) }}</span>
    </div>
    <div class="chat-stats-row">
      <span class="chat-stats-label">Cost (USD)</span>
      <span>{{ formatCost(stats?.cost) }}</span>
    </div>
  </div>
</template>

<script setup lang="ts">
import type { ChatUsageStats } from '@/types/api';
import {
  formatStepCost as formatCost,
  formatStepDurationMs as formatDurationMs,
  formatStepMetric as formatMetric,
  formatTokensPerSecond,
} from '@/utils/stepStats';

interface Props {
  stats: ChatUsageStats | null | undefined;
}

defineProps<Props>();
</script>

<style scoped>
.chat-stats-row {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  font-size: 0.95em;
  padding: 6px 0;
  border-bottom: 1px solid var(--color-border);
}

.chat-stats-row:last-child {
  border-bottom: none;
}

.chat-stats-label {
  color: var(--color-text-muted);
}
</style>
