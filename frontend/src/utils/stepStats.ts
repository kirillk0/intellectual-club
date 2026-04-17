const isFiniteNumber = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value);

export const formatStepMetric = (value: unknown): string => {
  if (value == null || value === '') return '—';
  return String(value);
};

export const formatStepCost = (value: unknown): string => {
  if (value == null || value === '') return '—';
  const num = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(num)) return String(value);
  const digits = Math.abs(num) > 0 && Math.abs(num) < 0.01 ? 8 : 6;
  return num.toFixed(digits);
};

export const formatStepDurationMs = (value: unknown): string => {
  const num = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(num) || num < 0) return '—';

  if (num < 1_000) return `${Math.round(num)} ms`;

  const seconds = num / 1_000;

  if (seconds < 10) return `${seconds.toFixed(2)} s`;
  if (seconds < 60) return `${seconds.toFixed(1)} s`;
  return `${seconds.toFixed(0)} s`;
};

export const formatTokensPerSecond = (value: unknown): string => {
  const num = typeof value === 'number' ? value : Number(value);
  if (!isFiniteNumber(num) || num < 0) return '—';

  const digits = num >= 100 ? 0 : num >= 10 ? 1 : 2;
  return `${num.toFixed(digits)} tok/s`;
};
