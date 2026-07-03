<template>
  <div class="stack usage-page">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>{{ translate('LLM Usage') }}</strong>
        <div class="header-actions toolbar-actions-right">
          <button type="button" @click="goBack">{{ translate('Back') }}</button>
        </div>
      </div>
    </StackToolbarTeleport>

    <section class="card usage-controls">
      <div class="usage-control-group">
        <span class="usage-control-label">{{ translate('Usage period') }}</span>
        <div class="segmented-control" :aria-label="translate('Usage period')">
          <button
            v-for="option in periodOptions"
            :key="option.value"
            type="button"
            :class="{ active: period === option.value }"
            @click="setPeriod(option.value)"
          >
            {{ translate(option.labelKey) }}
          </button>
        </div>
      </div>

      <div class="usage-date-fields" :class="{ disabled: period !== 'custom' }">
        <label>
          {{ translate('From') }}
          <input v-model="fromDate" type="date" :disabled="period !== 'custom'" @change="handleDateRangeChange" />
        </label>
        <label>
          {{ translate('To') }}
          <input v-model="toDate" type="date" :disabled="period !== 'custom'" @change="handleDateRangeChange" />
        </label>
      </div>

      <div class="usage-control-group usage-metrics-control">
        <span class="usage-control-label">{{ translate('Metrics') }}</span>
        <div class="usage-metric-toggles" role="group" :aria-label="translate('Metrics')">
          <button
            v-for="metric in usageMetricOptions"
            :key="metric.id"
            type="button"
            class="usage-metric-toggle"
            :class="{ active: isMetricVisible(metric.id) }"
            :aria-pressed="isMetricVisible(metric.id)"
            :disabled="isMetricToggleDisabled(metric.id)"
            @click="toggleMetric(metric.id)"
          >
            {{ metric.label }}
          </button>
        </div>
      </div>
    </section>

    <p v-if="loading" class="muted">{{ translate('Loading…') }}</p>
    <p v-else-if="error" class="error-text">{{ error }}</p>

    <section v-else class="card stack usage-table-card">
      <div class="usage-table-meta">
        <span>{{ fromDate }} – {{ toDate }}</span>
        <span>{{ translate('Configurations: {count}', { count: visibleRows.length }) }}</span>
        <span>{{ translate('Users: {count}', { count: users.length }) }}</span>
      </div>

      <div v-if="!visibleRows.length" class="muted">{{ translate('No usage found for this period.') }}</div>
      <div v-else-if="!users.length" class="muted">{{ translate('No usage found for this period.') }}</div>
      <div v-else class="usage-table-wrap">
        <table class="usage-table">
          <colgroup>
            <col class="usage-table__config-col-size" />
            <col v-for="user in users" :key="`col-${user.id}`" class="usage-table__user-col-size" />
          </colgroup>
          <thead>
            <tr>
              <th class="usage-table__config-col">{{ translate('Configuration') }}</th>
              <th v-for="user in users" :key="user.id" class="usage-table__user-col">
                <span data-i18n-ignore>{{ user.username }}</span>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="row in visibleRows" :key="row.key">
              <th class="usage-table__config-col" scope="row">
                <span class="usage-config-label" data-i18n-ignore>{{ row.label }}</span>
                <span v-if="row.deleted" class="badge">{{ translate('Deleted') }}</span>
                <span v-else-if="row.shared_incoming" class="badge">{{ translate('Shared with you') }}</span>
                <span v-else-if="row.shared_outgoing" class="badge">{{ translate('Shared') }}</span>
              </th>
              <td v-for="user in users" :key="`${row.key}-${user.id}`">
                <div class="usage-cell">
                  <template v-if="hasCellUsage(cellFor(row, user.id))">
                    <span v-for="metric in visibleUsageMetrics" :key="metric.id" class="usage-cell__metric">
                      <span class="usage-cell__metric-label">{{ metric.cellLabel }}</span>
                      <span class="usage-cell__metric-value">{{ formatMetricValue(metric.id, cellFor(row, user.id)) }}</span>
                    </span>
                  </template>
                  <span v-else class="usage-cell__empty" :aria-label="translate('No usage')">-</span>
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
import { computed, onMounted, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { api, getApiErrorMessage } from '@/api/client';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import { translate } from '@/i18n';

type Period = 'day' | 'week' | 'month' | 'custom';
type UsageMetricId =
  | 'messages'
  | 'steps'
  | 'cost'
  | 'cache_hit'
  | 'input_tokens_m'
  | 'cached_input_tokens_m'
  | 'output_tokens_m';

type UsageUser = {
  id: number;
  username: string;
};

type UsageCell = {
  message_count: number;
  step_count: number;
  input_tokens: number;
  cached_input_tokens: number;
  output_tokens: number;
  cache_hit_percent?: number | null;
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

const usageMetricIds: UsageMetricId[] = [
  'messages',
  'steps',
  'cost',
  'cache_hit',
  'input_tokens_m',
  'cached_input_tokens_m',
  'output_tokens_m',
];
const defaultVisibleMetricIds: UsageMetricId[] = ['messages', 'steps', 'cost'];
const usageMetricsStorageKey = 'ic.llm_usage.visible_metrics.v1';
const usagePeriodStorageKey = 'ic.llm_usage.period.v1';

const periodOptions: { value: Period; labelKey: string }[] = [
  { value: 'day', labelKey: 'Day' },
  { value: 'week', labelKey: 'Week' },
  { value: 'month', labelKey: 'Month' },
  { value: 'custom', labelKey: 'Custom' },
];

const usageMetricDefinitions: { id: UsageMetricId; labelKey: string; cellLabelKey: string }[] = [
  { id: 'messages', labelKey: 'Messages', cellLabelKey: 'Messages' },
  { id: 'steps', labelKey: 'Steps', cellLabelKey: 'Steps' },
  { id: 'cost', labelKey: 'Cost', cellLabelKey: 'Cost' },
  { id: 'cache_hit', labelKey: 'Cache hit %', cellLabelKey: 'Cache hit %' },
  { id: 'input_tokens_m', labelKey: 'Input tok.', cellLabelKey: 'Input' },
  { id: 'cached_input_tokens_m', labelKey: 'Cached input tok.', cellLabelKey: 'Cached input' },
  { id: 'output_tokens_m', labelKey: 'Output tok.', cellLabelKey: 'Output' },
];

const restoredPeriodState = loadUsagePeriodState();
const period = ref<Period>(restoredPeriodState.period);
const fromDate = ref(restoredPeriodState.from || '');
const toDate = ref(restoredPeriodState.to || '');
const loading = ref(false);
const error = ref<string | null>(null);
const users = ref<UsageUser[]>([]);
const rows = ref<UsageRow[]>([]);
const visibleMetricIds = ref<UsageMetricId[]>(loadVisibleMetricIds());

const emptyCell: UsageCell = {
  message_count: 0,
  step_count: 0,
  input_tokens: 0,
  cached_input_tokens: 0,
  output_tokens: 0,
  cache_hit_percent: null,
  cost: 0,
};

const returnTo = computed(() => {
  const value = route.query.returnTo;
  return typeof value === 'string' && value.startsWith('/') ? value : '/catalogs/llm-configurations';
});

const visibleRows = computed(() =>
  rows.value.filter((row) => Object.values(row.cells || {}).some((cell) => hasCellUsage(cell))),
);

const visibleMetricIdSet = computed(() => new Set(visibleMetricIds.value));
const usageMetricOptions = computed(() =>
  usageMetricDefinitions.map((metric) => ({
    ...metric,
    label: translate(metric.labelKey),
    cellLabel: translate(metric.cellLabelKey),
  })),
);
const visibleUsageMetrics = computed(() =>
  usageMetricOptions.value.filter((metric) => visibleMetricIdSet.value.has(metric.id)),
);

function parseVisibleMetricIds(value: unknown): UsageMetricId[] {
  if (!Array.isArray(value)) return [...defaultVisibleMetricIds];

  const next = new Set<UsageMetricId>();
  for (const item of value) {
    if (typeof item !== 'string') continue;
    if (usageMetricIds.includes(item as UsageMetricId)) next.add(item as UsageMetricId);
  }

  if (!next.size) return [...defaultVisibleMetricIds];
  return usageMetricIds.filter((id) => next.has(id));
}

function loadVisibleMetricIds(): UsageMetricId[] {
  if (typeof window === 'undefined') return [...defaultVisibleMetricIds];

  try {
    const raw = window.localStorage.getItem(usageMetricsStorageKey);
    if (!raw) return [...defaultVisibleMetricIds];
    return parseVisibleMetricIds(JSON.parse(raw));
  } catch (_e) {
    return [...defaultVisibleMetricIds];
  }
}

function saveVisibleMetricIds(metricIds: UsageMetricId[]) {
  if (typeof window === 'undefined') return;

  try {
    window.localStorage.setItem(usageMetricsStorageKey, JSON.stringify(metricIds));
  } catch (_e) {
    // Ignore private mode storage failures.
  }
}

function isPeriod(value: unknown): value is Period {
  return typeof value === 'string' && periodOptions.some((option) => option.value === value);
}

function isIsoDate(value: unknown): value is string {
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/u.test(value);
}

function isValidDateRange(from: unknown, to: unknown) {
  return isIsoDate(from) && isIsoDate(to) && from <= to;
}

function loadUsagePeriodState(): { period: Period; from?: string; to?: string } {
  if (typeof window === 'undefined') return { period: 'month' };

  try {
    const raw = window.localStorage.getItem(usagePeriodStorageKey);
    if (!raw) return { period: 'month' };

    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object') return { period: 'month' };

    const storedPeriod = (parsed as { period?: unknown }).period;
    if (!isPeriod(storedPeriod)) return { period: 'month' };

    const storedFrom = (parsed as { from?: unknown }).from;
    const storedTo = (parsed as { to?: unknown }).to;

    if (storedPeriod === 'custom') {
      if (isIsoDate(storedFrom) && isIsoDate(storedTo) && storedFrom <= storedTo) {
        return { period: storedPeriod, from: storedFrom, to: storedTo };
      }

      return { period: 'month' };
    }

    return { period: storedPeriod };
  } catch (_e) {
    return { period: 'month' };
  }
}

function saveUsagePeriodState() {
  if (typeof window === 'undefined') return;

  try {
    const payload =
      period.value === 'custom' && isValidDateRange(fromDate.value, toDate.value)
        ? { period: period.value, from: fromDate.value, to: toDate.value }
        : { period: period.value };
    window.localStorage.setItem(usagePeriodStorageKey, JSON.stringify(payload));
  } catch (_e) {
    // Ignore private mode storage failures.
  }
}

function isMetricVisible(metricId: UsageMetricId) {
  return visibleMetricIdSet.value.has(metricId);
}

function isMetricToggleDisabled(metricId: UsageMetricId) {
  return visibleMetricIds.value.length <= 1 && isMetricVisible(metricId);
}

function toggleMetric(metricId: UsageMetricId) {
  const next = new Set(visibleMetricIds.value);

  if (next.has(metricId)) {
    if (next.size <= 1) return;
    next.delete(metricId);
  } else {
    next.add(metricId);
  }

  visibleMetricIds.value = usageMetricIds.filter((id) => next.has(id));
}

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

function daysInMonth(year: number, monthIndex: number) {
  return new Date(year, monthIndex + 1, 0).getDate();
}

function subtractCalendarMonth(date: Date) {
  const targetMonth = new Date(date.getFullYear(), date.getMonth() - 1, 1);
  const targetDay = Math.min(date.getDate(), daysInMonth(targetMonth.getFullYear(), targetMonth.getMonth()));
  return new Date(targetMonth.getFullYear(), targetMonth.getMonth(), targetDay);
}

function setRangeForPeriod(nextPeriod: Period) {
  const today = startOfToday();
  const from = new Date(today);

  if (nextPeriod === 'week') {
    from.setDate(today.getDate() - 6);
  } else if (nextPeriod === 'month') {
    from.setTime(subtractCalendarMonth(today).getTime());
  }

  if (nextPeriod !== 'custom') {
    fromDate.value = localDateIso(from);
    toDate.value = localDateIso(today);
  }
}

function setPeriod(nextPeriod: Period) {
  period.value = nextPeriod;
  setRangeForPeriod(nextPeriod);
  saveUsagePeriodState();
  void loadUsage();
}

function handleDateRangeChange() {
  saveUsagePeriodState();
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
  return (
    Number(cell.message_count) > 0 ||
    Number(cell.step_count) > 0 ||
    Number(cell.input_tokens) > 0 ||
    Number(cell.cached_input_tokens) > 0 ||
    Number(cell.output_tokens) > 0 ||
    Number(cell.cost) > 0
  );
}

function formatInteger(value: unknown) {
  const number = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(number)) return '-';
  return String(Math.trunc(number));
}

function formatCost(value: unknown) {
  const cost = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(cost) || cost <= 0) return '$0.00';
  if (cost < 0.01) return `$${cost.toFixed(6)}`;
  return `$${cost.toFixed(2)}`;
}

function formatMillionTokens(value: unknown) {
  const tokens = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(tokens) || tokens < 0) return '-';
  if (tokens === 0) return '0.000M';

  const millions = tokens / 1_000_000;
  if (millions < 0.001) return '<0.001M';
  if (millions < 10) return `${millions.toFixed(3)}M`;
  if (millions < 100) return `${millions.toFixed(2)}M`;
  return `${millions.toFixed(1)}M`;
}

function formatPercent(value: unknown) {
  const percent = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(percent)) return '-';
  return `${percent.toFixed(1)}%`;
}

function formatMetricValue(metricId: UsageMetricId, cell: UsageCell) {
  if (metricId === 'messages') return formatInteger(cell.message_count);
  if (metricId === 'steps') return formatInteger(cell.step_count);
  if (metricId === 'cost') return formatCost(cell.cost);
  if (metricId === 'cache_hit') return cell.cache_hit_percent == null ? '-' : formatPercent(cell.cache_hit_percent);
  if (metricId === 'input_tokens_m') return formatMillionTokens(cell.input_tokens);
  if (metricId === 'cached_input_tokens_m') return formatMillionTokens(cell.cached_input_tokens);
  return formatMillionTokens(cell.output_tokens);
}

function goBack() {
  if (stackNav.isStackActive.value) {
    stackNav.close();
    return;
  }
  router.push(returnTo.value);
}

watch(visibleMetricIds, (metricIds) => saveVisibleMetricIds(metricIds));

onMounted(() => {
  if (period.value !== 'custom') {
    setRangeForPeriod(period.value);
  }

  saveUsagePeriodState();
  void loadUsage();
});
</script>

<style scoped>
.usage-page {
  min-width: 0;
}

.usage-controls {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
}

.usage-control-group {
  display: flex;
  flex-direction: column;
  gap: 6px;
  min-width: 0;
}

.usage-control-label {
  color: var(--color-text-muted);
  font-size: 0.82rem;
  font-weight: 600;
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

.usage-metrics-control {
  flex: 1 1 360px;
}

.usage-metric-toggles {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
}

.usage-metric-toggle {
  border: 1px solid var(--color-border-strong);
  border-radius: 8px;
  background: var(--color-surface);
  color: var(--color-text);
  min-height: 34px;
  padding: 6px 9px;
  white-space: nowrap;
}

.usage-metric-toggle.active {
  background: var(--color-primary);
  border-color: var(--color-primary);
  color: var(--color-primary-contrast);
}

.usage-metric-toggle:disabled {
  cursor: default;
  opacity: 0.72;
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
  width: fit-content;
  max-width: 100%;
}

.usage-table {
  --usage-config-column-width: 280px;
  --usage-user-column-width: 240px;

  width: max-content;
  min-width: 0;
  border-collapse: separate;
  border-spacing: 0;
  table-layout: fixed;
}

.usage-table__config-col-size {
  width: var(--usage-config-column-width);
}

.usage-table__user-col-size {
  width: var(--usage-user-column-width);
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
  width: var(--usage-config-column-width);
  min-width: var(--usage-config-column-width);
  max-width: var(--usage-config-column-width);
  position: sticky;
  left: 0;
  z-index: 1;
  text-align: left;
}

.usage-table thead .usage-table__config-col {
  z-index: 3;
}

.usage-table__user-col {
  width: var(--usage-user-column-width);
  min-width: var(--usage-user-column-width);
  max-width: var(--usage-user-column-width);
  text-align: left;
}

.usage-table tbody td {
  width: var(--usage-user-column-width);
  min-width: var(--usage-user-column-width);
  max-width: var(--usage-user-column-width);
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

.usage-cell__metric {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 8px;
  min-width: 0;
}

.usage-cell__metric-label {
  min-width: 0;
  overflow-wrap: anywhere;
}

.usage-cell__metric-value {
  color: var(--color-text);
  font-weight: 600;
  white-space: nowrap;
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
  .usage-date-fields,
  .usage-metrics-control {
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
