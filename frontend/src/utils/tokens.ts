import { effectiveLocale } from '@/i18n';

const toInteger = (value: unknown, fallback: number) => {
  const number = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.trunc(number);
};

export const formatTokenCount = (value: unknown, fallback = 0): string => {
  const integer = toInteger(value, fallback);
  return new Intl.NumberFormat(effectiveLocale.value, {
    maximumFractionDigits: 0,
  }).format(integer);
};

export const formatEstimatedTokens = (value: unknown, fallback = 0): string =>
  `~${formatTokenCount(value, fallback)} tokens`;
