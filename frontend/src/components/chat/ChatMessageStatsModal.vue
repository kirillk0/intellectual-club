<template>
  <ModalWindow
    :open="open"
    :modal-class="['message-stats-modal', { 'message-stats-modal--columns': Boolean(columns) }]"
    aria-label="Message stats"
    @cancel="emit('close')"
  >
    <h3 style="margin: 0">Message stats</h3>

    <div class="message-stats-panel">
      <template v-if="stats || subchatStats">
        <ChatStatsRows :stats="stats" :columns="columns" />
        <p v-if="columns" class="muted message-stats-note">
          {{ translate('Subchats are counted in tokens and cost only.') }}
        </p>
      </template>
      <p v-else class="muted message-stats-empty">Message stats unavailable.</p>
    </div>

    <div class="modal-actions">
      <div class="spacer"></div>
      <button type="button" @click="emit('close')">Close</button>
    </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import ModalWindow from '@/components/ModalWindow.vue';
import ChatStatsRows, { type ChatStatsColumn } from '@/components/chat/ChatStatsRows.vue';
import { translate } from '@/i18n';
import type { ChatUsageStats } from '@/types/api';
import { combineUsageWithSubchats } from '@/utils/stepStats';

interface Props {
  open: boolean;
  stats: ChatUsageStats | null;
  /** Usage of the message's subchat tree; null when the message has no subchats. */
  subchatStats?: ChatUsageStats | null;
}

const props = defineProps<Props>();

const emit = defineEmits<{
  (e: 'close'): void;
}>();

const columns = computed<ChatStatsColumn[] | null>(() => {
  if (!props.subchatStats) return null;
  return [
    { key: 'own', label: translate('Without subchats'), stats: props.stats },
    {
      key: 'with-subchats',
      label: translate('With subchats'),
      stats: combineUsageWithSubchats(props.stats, props.subchatStats),
    },
  ];
});
</script>

<style scoped>
:global(.message-stats-modal) {
  max-width: 560px;
}

:global(.message-stats-modal--columns) {
  max-width: 680px;
}

.message-stats-panel {
  margin-top: 10px;
  /* The modal is a grid; let wide stat columns shrink instead of overflowing. */
  min-width: 0;
}

.message-stats-empty {
  margin: 0;
}

.message-stats-note {
  margin: 8px 0 0;
  font-size: 0.85em;
}
</style>
