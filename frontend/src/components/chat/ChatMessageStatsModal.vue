<template>
  <ModalWindow
    :open="open"
    modal-class="message-stats-modal"
    aria-label="Message stats"
    @cancel="emit('close')"
  >
    <h3 style="margin: 0">Message stats</h3>

    <div class="message-stats-panel">
      <ChatStatsRows v-if="stats" :stats="stats" />
      <p v-else class="muted message-stats-empty">Message stats unavailable.</p>
    </div>

    <div class="modal-actions">
      <div class="spacer"></div>
      <button type="button" @click="emit('close')">Close</button>
    </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import ModalWindow from '@/components/ModalWindow.vue';
import ChatStatsRows from '@/components/chat/ChatStatsRows.vue';
import type { ChatUsageStats } from '@/types/api';

interface Props {
  open: boolean;
  stats: ChatUsageStats | null;
}

defineProps<Props>();

const emit = defineEmits<{
  (e: 'close'): void;
}>();
</script>

<style scoped>
:global(.message-stats-modal) {
  max-width: 560px;
}

.message-stats-panel {
  margin-top: 10px;
}

.message-stats-empty {
  margin: 0;
}
</style>
