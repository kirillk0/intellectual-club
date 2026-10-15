import type { ChatUsageStats } from '@/types/api';
import { formatTokenCount } from '@/utils/tokens';

const isFiniteNumber = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value);

export const subtractIncludedTokens = (total: unknown, included: unknown): number | null => {
  if (!isFiniteNumber(total) || !isFiniteNumber(included)) return null;
  return Math.max(total - included, 0);
};

const sumKnown = (left: unknown, right: unknown): number | null => {
  const a = isFiniteNumber(left) ? left : null;
  const b = isFiniteNumber(right) ? right : null;
  if (a == null) return b;
  if (b == null) return a;
  return a + b;
};

/**
 * Message usage plus its subchat tree. Subchat totals come from the usage
 * ledger, which has tokens and cost but no timing, so latency and speed stay
 * unknown instead of mixing unrelated generations.
 */
export const combineUsageWithSubchats = (
  own: ChatUsageStats | null | undefined,
  subchats: ChatUsageStats | null | undefined
): ChatUsageStats => ({
  input_tokens: sumKnown(own?.input_tokens, subchats?.input_tokens),
  cached_input_tokens: sumKnown(own?.cached_input_tokens, subchats?.cached_input_tokens),
  output_tokens: sumKnown(own?.output_tokens, subchats?.output_tokens),
  reasoning_tokens: sumKnown(own?.reasoning_tokens, subchats?.reasoning_tokens),
  time_to_first_token_ms: null,
  tokens_per_second: null,
  cost: sumKnown(own?.cost, subchats?.cost),
});

export const formatStepMetric = (value: unknown): string => {
  if (value == null || value === '') return '—';
  const num = typeof value === 'number' ? value : Number(value);
  if (Number.isFinite(num)) return formatTokenCount(num);
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
  if (value == null || value === '') return '—';
  const num = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(num) || num < 0) return '—';

  if (num < 1_000) return `${Math.round(num)} ms`;

  const seconds = num / 1_000;

  if (seconds < 10) return `${seconds.toFixed(2)} s`;
  if (seconds < 60) return `${seconds.toFixed(1)} s`;
  return `${seconds.toFixed(0)} s`;
};

export const formatTokensPerSecond = (value: unknown): string => {
  if (value == null || value === '') return '—';
  const num = typeof value === 'number' ? value : Number(value);
  if (!isFiniteNumber(num) || num < 0) return '—';

  const digits = num >= 100 ? 0 : num >= 10 ? 1 : 2;
  return `${num.toFixed(digits)} tok/s`;
};
