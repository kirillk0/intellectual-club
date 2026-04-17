<template>
  <transition name="fade">
    <div v-if="open" class="modal-backdrop" @click.self="emit('close')">
      <div class="modal" style="max-width: 520px">
        <h3 style="margin: 0">Step info</h3>
        <div class="stack" style="gap: 8px; margin-top: 8px">
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
        </div>
        <div class="modal-actions">
          <div class="spacer"></div>
          <button type="button" @click="emit('close')">Close</button>
        </div>
      </div>
    </div>
  </transition>
</template>

<script setup lang="ts">
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
}

defineProps<Props>();
const emit = defineEmits<{ (e: 'close'): void }>();

</script>

<style scoped>
.step-info-row {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  font-size: 0.95em;
}

.step-info-label {
  color: #6b7280;
}
</style>
