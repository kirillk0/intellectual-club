import { getEffectiveLocale, translate } from '@/i18n';

const parseIsoDate = (iso?: string | null): Date | null => {
  if (!iso) return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  return date;
};

export const formatRelativeDateTime = (iso?: string | null): string => {
  const date = parseIsoDate(iso);
  if (!date) return '';

  const now = new Date();
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const startOfYesterday = new Date(startOfToday);
  startOfYesterday.setDate(startOfYesterday.getDate() - 1);
  const isSameDay = (a: Date, b: Date) =>
    a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();

  const locale = getEffectiveLocale() === 'ru' ? 'ru-RU' : 'en-GB';
  const timePart = date.toLocaleTimeString(locale, {
    hour12: false,
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });

  if (isSameDay(date, startOfToday)) {
    return translate('Today, {time}', { time: timePart });
  }

  if (isSameDay(date, startOfYesterday)) {
    return translate('Yesterday, {time}', { time: timePart });
  }

  const datePart = date.toLocaleDateString(locale, {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });

  return `${datePart}, ${timePart}`;
};

export const formatTimeOfDay = (iso?: string | null): string => {
  const date = parseIsoDate(iso);
  if (!date) return '';

  const locale = getEffectiveLocale() === 'ru' ? 'ru-RU' : 'en-GB';

  return date.toLocaleTimeString(locale, {
    hour12: false,
    hour: '2-digit',
    minute: '2-digit',
  });
};

export const displayTimestampIso = (
  value?: { finished_at?: string | null; created_at?: string | null } | null
): string | null => {
  if (!value) return null;
  return value.finished_at || value.created_at || null;
};
