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

import { translate } from '@/i18n';

import type { KnowledgeBlockTab } from './types';

const props = defineProps<{
  modelValue: KnowledgeBlockTab;
  tagsCount: number;
  filesCount: number;
}>();

const emit = defineEmits<{
  (e: 'update:modelValue', value: KnowledgeBlockTab): void;
}>();

const tabs = computed<Array<{ value: KnowledgeBlockTab; label: string }>>(() => [
  { value: 'code', label: translate('Code') },
  { value: 'tags', label: `${translate('Tags')} (${props.tagsCount})` },
  { value: 'files', label: `${translate('Files')} (${props.filesCount})` },
  { value: 'secrets', label: translate('Secrets') },
  { value: 'details', label: translate('Details') },
]);
</script>
