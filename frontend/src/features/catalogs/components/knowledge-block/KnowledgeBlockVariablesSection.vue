<template>
  <div class="stack">
    <strong>Variables</strong>
    <VariablesTable :modelValue="variablesRows" @update:modelValue="setVariablesRows" />
    <div class="muted">Variables are exposed to prompts as <code v-text="'{{key}}'"></code>.</div>
  </div>
</template>

<script setup lang="ts">
import { ref, watch } from 'vue';

import VariablesTable from '@/components/VariablesTable.vue';

type VarRow = { key: string; value: string };

const props = defineProps<{
  variables: Record<string, string>;
}>();

const emit = defineEmits<{
  (e: 'update:variables', value: Record<string, string>): void;
}>();

const mapToVarRows = (vars: Record<string, unknown> | null | undefined): VarRow[] => {
  return Object.entries(vars || {})
    .map(([key, value]) => ({ key: String(key || ''), value: String(value ?? '') }))
    .sort((a, b) => a.key.localeCompare(b.key));
};

const varRowsToMap = (rows: VarRow[] | null | undefined): Record<string, string> => {
  const next: Record<string, string> = {};
  for (const row of rows || []) {
    const key = String(row.key || '').trim();
    if (!key) continue;
    next[key] = String(row.value ?? '');
  }
  return next;
};

const stableVarMap = (vars: Record<string, string>) => JSON.stringify(Object.entries(vars).sort(([a], [b]) => a.localeCompare(b)));

const variablesRows = ref<VarRow[]>([]);

watch(
  () => props.variables,
  (value) => {
    const incoming = varRowsToMap(mapToVarRows((value || {}) as Record<string, unknown>));
    const current = varRowsToMap(variablesRows.value);
    if (stableVarMap(incoming) === stableVarMap(current)) return;
    variablesRows.value = mapToVarRows((value || {}) as Record<string, unknown>);
  },
  { immediate: true, deep: true }
);

const setVariablesRows = (rows: VarRow[]) => {
  variablesRows.value = (rows || []).map((row) => ({ key: String(row.key || ''), value: String(row.value ?? '') }));
  emit('update:variables', varRowsToMap(variablesRows.value));
};
</script>

