<template>
  <section class="fork-context" :aria-label="translate('Inherited context')">
    <p class="fork-context__summary muted" :title="translate('Linked fork history is read-only. Send a follow-up instead.')">
      <SvgIcon name="branch" size="14" class="fork-context__icon" />
      <span v-if="context.status === 'unavailable'" role="status">
        {{ translate('Inherited context is unavailable. The source may have been deleted or access was revoked.') }}
      </span>
      <span v-else>{{ summary }}</span>
    </p>
    <!-- The task is the first instruction of the fork, shown like a user message without history actions. -->
    <div v-if="taskHtml" class="message user fork-context__task">
      <div class="bubble">
        <div class="fork-context__task-label">{{ translate('Fork task') }}</div>
        <div ref="taskEl" class="message-content" v-html="taskHtml"></div>
      </div>
    </div>
  </section>
</template>

<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { translate } from '@/i18n';
import type { ForkContext } from '@/types/api';
import { enhanceRenderedChatMessageHtml, renderChatMessageHtml } from '@/utils/chatMarkdown';

const props = defineProps<{ context: ForkContext }>();
const taskEl = ref<HTMLElement | null>(null);

const summary = computed(() =>
  [
    translate('Inherited context'),
    translate('Messages: {count}', { count: props.context.message_count ?? 0 }),
    translate('Steps: {count}', { count: props.context.step_count ?? 0 }),
    translate('history is read-only'),
  ].join(' · ')
);

const taskHtml = computed(() => {
  const task = props.context.task?.trim();
  return task ? renderChatMessageHtml(task) : '';
});

watch(
  taskHtml,
  () =>
    void nextTick(() => {
      if (taskEl.value) void enhanceRenderedChatMessageHtml(taskEl.value);
    }),
  { immediate: true }
);
</script>

<style scoped>
.fork-context { display: flex; flex-direction: column; gap: 8px; }
.fork-context__summary { display: flex; align-items: center; gap: 6px; margin: 0 8px; font-size: 0.85rem; }
.fork-context__icon { flex: 0 0 auto; }
.fork-context__task-label {
  margin-bottom: 4px;
  color: var(--color-text-muted);
  font-size: 0.78rem;
  font-weight: 600;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}
</style>
