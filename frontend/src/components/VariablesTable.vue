<template>
  <div class="vars-wrap">
    <template v-if="rows.length">
      <table class="vars-grid">
        <thead>
          <tr>
            <th style="width: 40%">Key</th>
            <th>Value</th>
            <th style="width: 42px"></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="(row, idx) in rows" :key="row.id ?? `row-${idx}`">
            <td>
              <input
                v-model="row.key"
                :disabled="readonly"
                @input="emitChange"
                placeholder="key"
                class="cell-input"
              />
            </td>
            <td>
              <input
                v-model="row.value"
                :disabled="readonly"
                @input="emitChange"
                placeholder="value"
                class="cell-input"
              />
            </td>
            <td class="cell-actions">
              <button type="button" class="cell-remove" :disabled="readonly" @click="remove(idx)">
                ✕
              </button>
            </td>
          </tr>
        </tbody>
      </table>
      <div class="vars-link">
        <button type="button" class="link-btn" :disabled="readonly" @click="add">
          + Add variable
        </button>
      </div>
    </template>
    <div v-else class="vars-empty">
      <button type="button" class="link-btn" :disabled="readonly" @click="add">+ Add variable</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { reactive, watch } from 'vue';

type Row = { id?: number | string; key: string; value: string };

const props = defineProps<{
  modelValue: Row[];
  readonly?: boolean;
}>();

const emit = defineEmits<{
  (e: 'update:modelValue', val: Row[]): void;
}>();

const rows = reactive<Row[]>(props.modelValue ? props.modelValue.map((r) => ({ ...r })) : []);

watch(
  () => props.modelValue,
  (val) => {
    rows.splice(0, rows.length, ...(val ? val.map((r) => ({ ...r })) : []));
  }
);

const emitChange = () => emit('update:modelValue', rows.map((r) => ({ ...r })));

const add = () => {
  rows.push({ key: '', value: '' });
  emitChange();
};

const remove = (idx: number) => {
  rows.splice(idx, 1);
  emitChange();
};
</script>

<style scoped>
.vars-wrap {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.vars-grid {
  width: 100%;
  border-collapse: collapse;
  font-size: 12px;
  border-spacing: 0;
}

.vars-grid th,
.vars-grid td {
  border: 1px solid var(--color-border-strong);
  padding: 4px;
}

.vars-grid th {
  background: var(--color-surface-muted);
  font-weight: 600;
  text-align: left;
}

.cell-input {
  width: 100%;
  border: none;
  border-radius: 0;
  padding: 2px 3px;
  font-size: 12px;
  box-sizing: border-box;
}

.cell-actions {
  text-align: center;
}

.cell-remove {
  border: 1px solid var(--color-border-strong);
  background: var(--color-surface);
  border-radius: 4px;
  padding: 2px 6px;
  font-size: 12px;
}

.vars-link {
  display: flex;
  justify-content: flex-start;
  padding: 2px 0;
}

.link-btn {
  border: none;
  background: none;
  color: var(--color-link);
  cursor: pointer;
  padding: 0;
  font-size: 13px;
}

.link-btn:hover {
  text-decoration: underline;
}
</style>

