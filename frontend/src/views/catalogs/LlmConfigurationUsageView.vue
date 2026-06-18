<template>
  <div class="stack usage-page">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>LLM Usage</strong>
        <div class="header-actions toolbar-actions-right">
          <button type="button" @click="goBack">Back</button>
        </div>
      </div>
    </StackToolbarTeleport>

    <section class="card usage-controls">
      <div class="segmented-control" aria-label="Usage period">
        <button
          v-for="option in periodOptions"
          :key="option.value"
          type="button"
          :class="{ active: period === option.value }"
          @click="setPeriod(option.value)"
        >
          {{ option.label }}
        </button>
      </div>

      <div class="usage-date-fields" :class="{ disabled: period !== 'custom' }">
        <label>
          From
          <input v-model="fromDate" type="date" :disabled="period !== 'custom'" @change="loadUsage" />
        </label>
        <label>
          To
          <input v-model="toDate" type="date" :disabled="period !== 'custom'" @change="loadUsage" />
        </label>
      </div>
    </section>

    <p v-if="loading" class="muted">Loading…</p>
    <p v-else-if="error" class="error-text">{{ error }}</p>

    <section v-else class="card stack usage-table-card">
      <div class="usage-table-meta">
        <span>{{ fromDate }} – {{ toDate }}</span>
        <span>{{ visibleRows.length }} configurations</span>
        <span>{{ users.length }} users</span>
      </div>

      <div v-if="!visibleRows.length" class="muted">No usage found for this period.</div>
      <div v-else-if="!users.length" class="muted">No usage found for this period.</div>
      <div v-else class="usage-table-wrap">
        <table class="usage-table">
          <thead>
            <tr>
              <th class="usage-table__config-col">Configuration</th>
              <th v-for="user in users" :key="user.id" class="usage-table__user-col">
                {{ user.username }}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="row in visibleRows" :key="row.key">
              <th class="usage-table__config-col" scope="row">
                <span class="usage-config-label">{{ row.label }}</span>
                <span v-if="row.deleted" class="badge">Deleted</span>
                <span v-else-if="row.shared_incoming" class="badge">Shared with you</span>
                <span v-else-if="row.shared_outgoing" class="badge">Shared</span>
              </th>
              <td v-for="user in users" :key="`${row.key}-${user.id}`">
                <div class="usage-cell">
                  <template v-if="hasCellUsage(cellFor(row, user.id))">
                    <span>{{ cellFor(row, user.id).message_count }} msg</span>
                    <span>{{ cellFor(row, user.id).step_count }} steps</span>
                    <span>{{ formatCost(cellFor(row, user.id).cost) }}</span>
                  </template>
                  <span v-else class="usage-cell__empty" aria-label="No usage">-</span>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { api, getApiErrorMessage } from '@/api/client';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { useStackNavigation } from '@/features/stack/useStackNavigation';

type Period = 'day' | 'week' | 'month' | 'custom';

type UsageUser = {
  id: number;
  username: string;
};

type UsageCell = {
  message_count: number;
  step_count: number;
  cost: number;
};

type UsageRow = {
  key: string;
  configuration_id?: number | null;
  configuration_external_id?: string | null;
  label: string;
  deleted: boolean;
  shared_incoming: boolean;
  shared_outgoing: boolean;
  cells: Record<string, UsageCell | undefined>;
};

type UsagePayload = {
  from: string;
  to: string;
  users: UsageUser[];
  rows: UsageRow[];
};

const route = useRoute();
const router = useRouter();
const stackNav = useStackNavigation();

const periodOptions: { value: Period; label: string }[] = [
  { value: 'day', label: 'Day' },
  { value: 'week', label: 'Week' },
  { value: 'month', label: 'Month' },
  { value: 'custom', label: 'Custom' },
];

const period = ref<Period>('month');
const fromDate = ref('');
const toDate = ref('');
const loading = ref(false);
const error = ref<string | null>(null);
const users = ref<UsageUser[]>([]);
const rows = ref<UsageRow[]>([]);

const emptyCell: UsageCell = {
  message_count: 0,
  step_count: 0,
  cost: 0,
};

const returnTo = computed(() => {
  const value = route.query.returnTo;
  return typeof value === 'string' && value.startsWith('/') ? value : '/catalogs/llm-configurations';
});

const visibleRows = computed(() =>
  rows.value.filter((row) => Object.values(row.cells || {}).some((cell) => hasCellUsage(cell))),
);

function localDateIso(date: Date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function startOfToday() {
  const now = new Date();
  return new Date(now.getFullYear(), now.getMonth(), now.getDate());
}

function setRangeForPeriod(nextPeriod: Period) {
  const today = startOfToday();
  const from = new Date(today);

  if (nextPeriod === 'week') {
    from.setDate(today.getDate() - 6);
  } else if (nextPeriod === 'month') {
    from.setDate(1);
  }

  if (nextPeriod !== 'custom') {
    fromDate.value = localDateIso(from);
    toDate.value = localDateIso(today);
  }
}

function setPeriod(nextPeriod: Period) {
  period.value = nextPeriod;
  setRangeForPeriod(nextPeriod);
  void loadUsage();
}

function normalizePayload(payload: UsagePayload) {
  users.value = Array.isArray(payload.users) ? payload.users : [];
  rows.value = Array.isArray(payload.rows) ? payload.rows : [];
}

async function loadUsage() {
  if (!fromDate.value || !toDate.value) return;

  loading.value = true;
  error.value = null;

  try {
    const params = new URLSearchParams();
    params.set('from', fromDate.value);
    params.set('to', toDate.value);
    const payload = await api.get<UsagePayload>(`/api/bff/llm-usage?${params.toString()}`);
    normalizePayload(payload);
  } catch (e) {
    console.error(e);
    error.value = getApiErrorMessage(e, 'Failed to load usage.');
  } finally {
    loading.value = false;
  }
}

function cellFor(row: UsageRow, userId: number): UsageCell {
  return row.cells?.[String(userId)] || emptyCell;
}

function hasCellUsage(cell: UsageCell | undefined) {
  if (!cell) return false;
  return Number(cell.message_count) > 0 || Number(cell.step_count) > 0 || Number(cell.cost) > 0;
}

function formatCost(value: unknown) {
  const cost = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(cost) || cost <= 0) return '$0.00';
  if (cost < 0.01) return `$${cost.toFixed(6)}`;
  return `$${cost.toFixed(2)}`;
}

function goBack() {
  if (stackNav.isStackActive.value) {
    stackNav.close();
    return;
  }
  router.push(returnTo.value);
}

onMounted(() => {
  setRangeForPeriod(period.value);
  void loadUsage();
});
</script>

<style scoped>
.usage-page {
  min-width: 0;
}

.usage-controls {
  display: flex;
  align-items: end;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
}

.segmented-control {
  display: inline-flex;
  align-items: center;
  border: 1px solid var(--color-border-strong);
  border-radius: 8px;
  overflow: hidden;
}

.segmented-control button {
  border: 0;
  border-right: 1px solid var(--color-border-strong);
  border-radius: 0;
  background: var(--color-surface);
  min-width: 76px;
}

.segmented-control button:last-child {
  border-right: 0;
}

.segmented-control button.active {
  background: var(--color-primary);
  color: var(--color-primary-contrast);
}

.usage-date-fields {
  display: inline-flex;
  align-items: end;
  gap: 10px;
  flex-wrap: wrap;
}

.usage-date-fields.disabled {
  opacity: 0.72;
}

.usage-date-fields label {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.usage-table-card {
  min-width: 0;
}

.usage-table-meta {
  display: flex;
  gap: 12px;
  flex-wrap: wrap;
  color: var(--color-text-muted);
  font-size: 0.9rem;
}

.usage-table-wrap {
  overflow: auto;
  border: 1px solid var(--color-border);
  border-radius: 8px;
}

.usage-table {
  width: 100%;
  min-width: 760px;
  border-collapse: separate;
  border-spacing: 0;
  table-layout: fixed;
}

.usage-table th,
.usage-table td {
  border-bottom: 1px solid var(--color-border);
  border-right: 1px solid var(--color-border);
  padding: 10px 12px;
  vertical-align: top;
  background: var(--color-surface);
}

.usage-table thead th {
  position: sticky;
  top: 0;
  z-index: 2;
  background: var(--color-surface-subtle);
  font-weight: 600;
}

.usage-table tr:last-child th,
.usage-table tr:last-child td {
  border-bottom: 0;
}

.usage-table th:last-child,
.usage-table td:last-child {
  border-right: 0;
}

.usage-table__config-col {
  width: 280px;
  position: sticky;
  left: 0;
  z-index: 1;
  text-align: left;
}

.usage-table thead .usage-table__config-col {
  z-index: 3;
}

.usage-table__user-col {
  min-width: 160px;
  text-align: left;
}

.usage-config-label {
  display: block;
  min-width: 0;
  overflow-wrap: anywhere;
  margin-bottom: 6px;
}

.usage-cell {
  display: grid;
  gap: 2px;
  color: var(--color-text-muted);
  font-size: 0.92rem;
  line-height: 1.35;
}

.usage-cell span:last-child {
  color: var(--color-text);
  font-weight: 600;
}

.usage-cell span.usage-cell__empty {
  color: var(--color-text-muted);
  font-weight: 400;
}

@media (max-width: 720px) {
  .usage-controls {
    align-items: stretch;
  }

  .segmented-control,
  .usage-date-fields {
    width: 100%;
  }

  .segmented-control button {
    flex: 1 1 0;
    min-width: 0;
  }

  .usage-date-fields label {
    flex: 1 1 140px;
  }
}
</style>
