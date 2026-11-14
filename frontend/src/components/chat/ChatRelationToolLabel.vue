<template>
  <small v-if="toolName" class="chat-relation-tool" :title="translate('Tool: {tool}', { tool: toolName })">
    {{ translate('via {tool}', { tool: toolName }) }}
  </small>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import { translate } from '@/i18n';

const props = defineProps<{ name?: string | null }>();
const toolName = computed(() => props.name?.trim());
</script>

<style scoped>
.chat-relation-tool {
  flex: 0 1 auto;
  min-width: 0;
  max-width: 45%;
  overflow: hidden;
  color: var(--color-text-muted);
  font-size: 0.8rem;
  text-overflow: ellipsis;
  white-space: nowrap;
}

@media (max-width: 600px) {
  .chat-relation-tool {
    order: 1;
    flex-basis: 100%;
    max-width: 100%;
    overflow-wrap: anywhere;
    white-space: normal;
  }
}
</style>
