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

interface Props {
  open: boolean;
  step: ChatMessageStep | null;
}

defineProps<Props>();
const emit = defineEmits<{ (e: 'close'): void }>();

const formatMetric = (value: unknown) => {
  if (value == null || value === '') return '—';
  return String(value);
};

const formatCost = (value: unknown) => {
  if (value == null || value === '') return '—';
  const num = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(num)) return String(value);
  const digits = Math.abs(num) > 0 && Math.abs(num) < 0.01 ? 8 : 6;
  return num.toFixed(digits);
};
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
