<template>
  <span v-if="visible" class="chat-relation-indicators">
    <span
      v-if="relation.background_task === true"
      class="chat-relation-indicators__background-task"
      role="img"
      :aria-label="backgroundTaskLabel"
      :title="backgroundTaskLabel"
    >
      <SvgIcon name="gear" size="14" />
    </span>
    <ChatGenerationStateIndicator :state="generationState" />
  </span>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import ChatGenerationStateIndicator from '@/components/chat/ChatGenerationStateIndicator.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { childRelationGenerationState } from '@/features/chat/model/chatRelations';
import { translate } from '@/i18n';
import type { ChatRelationSummary } from '@/types/api';

const props = defineProps<{
  relation: ChatRelationSummary;
}>();

const generationState = computed(() => childRelationGenerationState(props.relation));
const visible = computed(
  () => props.relation.background_task === true || generationState.value !== null
);
const backgroundTaskLabel = computed(() => translate('Started as a background task'));
</script>

<style scoped>
.chat-relation-indicators {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  flex: 0 0 auto;
}

.chat-relation-indicators__background-task {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 18px;
  height: 18px;
  color: var(--color-text-muted);
}
</style>
