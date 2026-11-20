<template>
  <template v-for="(part, index) in parts" :key="index">
    <mark v-if="part.match">{{ part.text }}</mark>
    <template v-else>{{ part.text }}</template>
  </template>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import { highlightSearchSnippet } from '@/features/chat/chatSearch';

const props = defineProps<{ text: string | null; terms: string[]; ordered: boolean }>();
const parts = computed(() => highlightSearchSnippet(props.text ?? '', props.terms, props.ordered));
</script>

<style scoped>
mark {
  padding: 0 1px;
  border-radius: 3px;
  background: color-mix(in srgb, var(--color-warning-border) 55%, transparent);
  color: inherit;
}
</style>
