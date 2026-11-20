<template>
  <section v-if="current" class="xlsx-preview" data-i18n-ignore :aria-label="title">
    <label class="xlsx-preview__sheet">
      {{ translate('Worksheet') }}
      <select v-model="selectedIndex">
        <option v-for="(sheet, index) in sheets" :key="index" :value="index">{{ sheet.sheet }}</option>
      </select>
    </label>
    <p v-if="truncated" class="muted" role="status">
      {{ translate('Preview limited to the first {rows} rows and {columns} columns.', { rows: MAX_ROWS, columns: MAX_COLUMNS }) }}
    </p>
    <div v-if="columnCount" :key="selectedIndex" class="xlsx-preview__grid" tabindex="0">
      <table :aria-label="current.sheet">
        <thead>
          <tr>
            <td></td>
            <th v-for="column in columnCount" :key="column" scope="col">{{ columnName(column) }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="(row, index) in visibleRows" :key="index">
            <th scope="row">{{ index + 1 }}</th>
            <td v-for="column in columnCount" :key="column">{{ formatCell(row[column - 1]) }}</td>
          </tr>
        </tbody>
      </table>
    </div>
    <p v-else class="muted">{{ translate('This worksheet is empty.') }}</p>
  </section>
</template>

<script setup lang="ts">
import { computed, onMounted, onScopeDispose, ref, shallowRef } from 'vue';
import readExcelFile, { type CellValue, type Sheet } from 'read-excel-file/browser';

import { translate } from '@/i18n';

const props = defineProps<{ file: Blob; title: string }>();
const emit = defineEmits<{ ready: []; error: [] }>();
const MAX_ROWS = 200;
const MAX_COLUMNS = 32;
const sheets = shallowRef<Sheet[]>([]);
const selectedIndex = ref(0);
const current = computed(() => sheets.value[selectedIndex.value]);
const visibleRows = computed(() => current.value?.data.slice(0, MAX_ROWS) ?? []);
const visibleWidth = computed(() => visibleRows.value.reduce((width, row) => Math.max(width, row.length), 0));
const columnCount = computed(() => Math.min(visibleWidth.value, MAX_COLUMNS));
const truncated = computed(() => (current.value?.data.length ?? 0) > MAX_ROWS || visibleWidth.value > MAX_COLUMNS);

const columnName = (column: number): string => {
  let name = '';
  while (column > 0) {
    column--;
    name = String.fromCharCode(65 + (column % 26)) + name;
    column = Math.floor(column / 26);
  }
  return name;
};

const formatCell = (value: CellValue | null | undefined) => {
  // Spreadsheet dates have no timezone. Keep their original calendar day and time.
  if (value instanceof Date) return value.toISOString().replace(/T00:00:00\.000Z$/u, '').replace('T', ' ').replace(/(?:\.000)?Z$/u, '');
  if (typeof value === 'boolean') return value ? 'TRUE' : 'FALSE';
  return value == null ? '' : String(value);
};

let disposed = false;
onScopeDispose(() => { disposed = true; });
onMounted(async () => {
  try {
    const result = await readExcelFile(props.file, { trim: false });
    if (disposed) return;
    if (!result.length) { emit('error'); return; }
    sheets.value = result;
    emit('ready');
  } catch {
    if (!disposed) emit('error');
  }
});
</script>

<style scoped>
.xlsx-preview {
  display: flex;
  flex-direction: column;
  gap: 8px;
  box-sizing: border-box;
  max-height: 70vh;
  min-height: 0;
}

.attachment-preview-content--fullscreen .xlsx-preview {
  height: 100%;
  max-height: none;
  padding: 12px;
  padding-top: calc(56px + var(--app-safe-area-top));
}

.xlsx-preview__sheet { display: flex; align-items: center; gap: 8px; }
.xlsx-preview__sheet select { min-width: 0; max-width: 100%; }
.xlsx-preview p { margin: 0; }
.xlsx-preview__grid { overflow: auto; }
.xlsx-preview table { border-collapse: separate; border-spacing: 0; }
.xlsx-preview th, .xlsx-preview td {
  padding: 3px 8px;
  border-right: 1px solid var(--color-border);
  border-bottom: 1px solid var(--color-border);
  max-width: 36ch;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  vertical-align: top;
}
.xlsx-preview th { background: var(--color-surface-muted); }
.xlsx-preview thead th { position: sticky; top: 0; }
</style>
