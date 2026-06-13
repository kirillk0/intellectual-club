<template>
  <div class="tabs">
    <button
      v-for="tab in tabs"
      :key="tab.value"
      class="tab"
      :class="{ active: modelValue === tab.value }"
      type="button"
      @click="emit('update:modelValue', tab.value)"
    >
      {{ tab.label }}
    </button>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import type { KnowledgeBlockTab } from './types';

const props = defineProps<{
  modelValue: KnowledgeBlockTab;
  filesCount: number;
}>();

const emit = defineEmits<{
  (e: 'update:modelValue', value: KnowledgeBlockTab): void;
}>();

const tabs = computed<Array<{ value: KnowledgeBlockTab; label: string }>>(() => [
  { value: 'code', label: 'Code' },
  { value: 'variables', label: 'Variables' },
  { value: 'tags', label: 'Tags' },
  { value: 'files', label: `Files (${props.filesCount})` },
  { value: 'details', label: 'Details' },
]);
</script>
