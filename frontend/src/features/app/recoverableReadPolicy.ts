const DEFAULT_RETRY_DELAYS_MS = [500, 1_500, 3_000, 5_000, 10_000] as const;
const MAX_RETRY_DELAY_MS = 10_000;
const MAX_RETRY_AFTER_MS = 60_000;
const RETRY_JITTER = 0.2;
const TRANSIENT_STATUS_CODES = new Set([408, 425, 429]);

const isAbortError = (error: unknown) =>
  error != null &&
  typeof error === 'object' &&
  'name' in error &&
  (error as { name?: unknown }).name === 'AbortError';

const httpStatus = (error: unknown) => {
  if (!error || typeof error !== 'object') return null;
  const candidate = error as { name?: unknown; status?: unknown };
  if (candidate.name !== 'HttpError' || typeof candidate.status !== 'number') return null;
  return candidate.status;
};

export const isTransientReadError = (error: unknown) => {
  const status = httpStatus(error);
  if (status !== null) {
    return TRANSIENT_STATUS_CODES.has(status) || status >= 500;
  }
  if (!(error instanceof Error) || isAbortError(error)) return false;
  return (
    error instanceof TypeError ||
    error.name === 'NetworkError' ||
    error.name === 'RequestTimeoutError'
  );
};

export const retryAfterDelayMs = (error: unknown, now = Date.now()) => {
  if (!error || typeof error !== 'object') return null;
  const raw = (error as { retryAfter?: unknown }).retryAfter;
  if (typeof raw !== 'string' || raw.trim() === '') return null;

  const seconds = Number(raw);
  const delay = Number.isFinite(seconds) ? seconds * 1_000 : Date.parse(raw) - now;
  if (!Number.isFinite(delay) || delay < 0) return null;
  return Math.min(MAX_RETRY_AFTER_MS, Math.round(delay));
};

const normalizeDelay = (value: number) =>
  Number.isFinite(value) ? Math.max(0, Math.floor(value)) : 0;

export const recoverableRetryDelayMs = (
  retryIndex: number,
  error?: unknown,
  delays: readonly number[] = DEFAULT_RETRY_DELAYS_MS,
  random: () => number = Math.random
) => {
  const retryAfter = retryAfterDelayMs(error);
  if (retryAfter !== null) return retryAfter;

  const base = normalizeDelay(
    delays[Math.min(retryIndex, delays.length - 1)] ?? MAX_RETRY_DELAY_MS
  );
  const capped = Math.min(MAX_RETRY_DELAY_MS, base);
  const jitter = 1 + (random() * 2 - 1) * RETRY_JITTER;
  return Math.round(capped * jitter);
};
