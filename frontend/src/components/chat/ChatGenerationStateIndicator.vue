<template>
  <span
    v-if="state"
    class="chat-generation-state"
    :class="`chat-generation-state--${state}`"
    role="status"
    aria-live="polite"
    aria-atomic="true"
    :aria-label="stateLabel"
    :title="stateLabel"
  >
    <span v-if="state === 'generating'" class="typing-indicator" aria-hidden="true">
      <span></span><span></span><span></span>
    </span>
    <span v-else-if="state === 'reconnecting'" class="reconnect-indicator" aria-hidden="true"></span>
    <SvgIcon v-else-if="state === 'done'" name="check" size="14" />
    <span v-else class="chat-generation-state__error-icon" aria-hidden="true">
      <SvgIcon name="x" size="12" />
    </span>
  </span>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { translate } from '@/i18n';

type ChatGenerationState = 'generating' | 'reconnecting' | 'done' | 'canceled' | 'error';

const props = defineProps<{
  state?: ChatGenerationState | null;
}>();

const stateLabel = computed(() => {
  if (props.state === 'done') return translate('Generation complete');
  if (props.state === 'canceled') return translate('Generation canceled');
  if (props.state === 'error') return translate('Generation failed');
  if (props.state === 'reconnecting') return translate('Reconnecting');
  return translate('Generating');
});
</script>

<style scoped>
.chat-generation-state {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: 0 0 auto;
  width: 36px;
  min-height: 18px;
}

.chat-generation-state--done {
  color: var(--color-success);
}

.chat-generation-state--error {
  color: var(--color-danger);
}

.chat-generation-state--canceled {
  color: var(--color-danger);
}

.chat-generation-state--reconnecting {
  color: var(--color-warning-text);
}

.chat-generation-state--reconnecting .reconnect-indicator {
  width: 14px;
  height: 14px;
}

.chat-generation-state__error-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 18px;
  height: 18px;
  border: 1.5px solid currentColor;
  border-radius: 999px;
}
</style>
