const toInteger = (value: unknown, fallback: number) => {
  const number = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.trunc(number);
};

export const formatEstimatedTokens = (value: unknown, fallback = 0): string =>
  `~${toInteger(value, fallback)} tokens`;
