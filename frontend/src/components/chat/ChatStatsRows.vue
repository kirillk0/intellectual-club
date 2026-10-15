<template>
  <div class="chat-stats-rows" :class="{ 'chat-stats-rows--multi': multiColumn }">
    <div v-if="multiColumn" class="chat-stats-header">
      <span class="chat-stats-label"></span>
      <span v-for="column in resolvedColumns" :key="column.key" class="chat-stats-value">{{ column.label }}</span>
    </div>

    <div v-for="group in tokenGroups" :key="group.key" class="chat-stats-token-group">
      <div class="chat-stats-row chat-stats-row--total">
        <span class="chat-stats-label">{{ translate(group.total.label) }}</span>
        <span v-for="column in resolvedColumns" :key="column.key" class="chat-stats-value">{{ group.total.format(column.stats) }}</span>
      </div>
      <div class="chat-stats-breakdown" :aria-label="translate(group.breakdownLabel)">
        <div v-for="row in group.parts" :key="row.key" class="chat-stats-row chat-stats-row--part">
          <span class="chat-stats-label">{{ translate(row.label) }}</span>
          <span v-for="column in resolvedColumns" :key="column.key" class="chat-stats-value">{{ row.format(column.stats) }}</span>
        </div>
      </div>
    </div>

    <div v-for="row in plainRows" :key="row.key" class="chat-stats-row">
      <span class="chat-stats-label">{{ translate(row.label) }}</span>
      <span v-for="column in resolvedColumns" :key="column.key" class="chat-stats-value">{{ row.format(column.stats) }}</span>
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

type Stats = ChatUsageStats | null | undefined;

export type ChatStatsColumn = {
  key: string;
  label: string;
  stats: Stats;
};

type StatsRow = {
  key: string;
  label: string;
  format: (stats: Stats) => string;
};

interface Props {
  /** Single unlabeled column. Ignored when `columns` is given. */
  stats?: Stats;
  /** Labeled side-by-side columns, e.g. a message with and without its subchats. */
  columns?: ChatStatsColumn[] | null;
}

const props = defineProps<Props>();

const resolvedColumns = computed<ChatStatsColumn[]>(() =>
  props.columns?.length ? props.columns : [{ key: 'stats', label: '', stats: props.stats }]
);
const multiColumn = computed(() => resolvedColumns.value.length > 1);

const tokenGroups: { key: string; breakdownLabel: string; total: StatsRow; parts: StatsRow[] }[] = [
  {
    key: 'input',
    breakdownLabel: 'Input token breakdown',
    total: {
      key: 'input',
      label: 'Input tokens (total)',
      format: (stats) => formatMetric(stats?.input_tokens),
    },
    parts: [
      {
        key: 'cold-input',
        label: 'Cold input tokens',
        format: (stats) =>
          formatMetric(subtractIncludedTokens(stats?.input_tokens, stats?.cached_input_tokens)),
      },
      {
        key: 'cached-input',
        label: 'Cached input tokens',
        format: (stats) => formatMetric(stats?.cached_input_tokens),
      },
    ],
  },
  {
    key: 'output',
    breakdownLabel: 'Output token breakdown',
    total: {
      key: 'output',
      label: 'Output tokens (total, incl. reasoning)',
      format: (stats) => formatMetric(stats?.output_tokens),
    },
    parts: [
      {
        key: 'non-reasoning-output',
        label: 'Non-reasoning output tokens',
        format: (stats) =>
          formatMetric(subtractIncludedTokens(stats?.output_tokens, stats?.reasoning_tokens)),
      },
      {
        key: 'reasoning',
        label: 'Reasoning tokens',
        format: (stats) => formatMetric(stats?.reasoning_tokens),
      },
    ],
  },
];

const plainRows: StatsRow[] = [
  {
    key: 'ttft',
    label: 'Time to first token',
    format: (stats) => formatDurationMs(stats?.time_to_first_token_ms),
  },
  {
    key: 'tps',
    label: 'Output speed (TPS)',
    format: (stats) => formatTokensPerSecond(stats?.tokens_per_second),
  },
  { key: 'cost', label: 'Cost (USD)', format: (stats) => formatCost(stats?.cost) },
];
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

.chat-stats-header {
  display: flex;
  gap: 12px;
  padding: 0 0 6px;
  border-bottom: 1px solid var(--color-border);
  font-size: 0.85em;
  font-weight: 600;
  color: var(--color-text-muted);
}

.chat-stats-rows--multi .chat-stats-label {
  flex: 1 1 auto;
  min-width: 0;
  overflow-wrap: anywhere;
}

/* Root-relative fixed widths keep columns aligned across rows with different font sizes. */
.chat-stats-rows--multi .chat-stats-value {
  flex: 0 0 8rem;
  text-align: right;
}

@media (max-width: 480px) {
  .chat-stats-rows--multi .chat-stats-value {
    flex-basis: 5rem;
  }
}
</style>
