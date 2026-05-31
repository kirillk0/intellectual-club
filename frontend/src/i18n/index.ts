import { computed, ref, watch } from 'vue';
import { createI18n } from 'vue-i18n';
import { messages, ruMessages } from './messages';

export const SUPPORTED_LOCALES = ['en', 'ru'] as const;
export const DEFAULT_LOCALE = 'en';

export type SupportedLocale = (typeof SUPPORTED_LOCALES)[number];
export type PreferredLocale = SupportedLocale | null;

const supportedLocaleSet = new Set<string>(SUPPORTED_LOCALES);
const browserLocale = ref<SupportedLocale>(DEFAULT_LOCALE);
const preferredLocale = ref<PreferredLocale>(null);

export const isSupportedLocale = (value: unknown): value is SupportedLocale =>
  typeof value === 'string' && supportedLocaleSet.has(value);

export const normalizeLocale = (value: unknown): SupportedLocale | null => {
  if (typeof value !== 'string') return null;
  const normalized = value.trim().toLowerCase().split(/[-_]/u)[0] || '';
  return isSupportedLocale(normalized) ? normalized : null;
};

export const normalizePreferredLocale = (value: unknown): PreferredLocale => normalizeLocale(value);

export const detectBrowserLocale = (): SupportedLocale => {
  if (typeof navigator === 'undefined') return DEFAULT_LOCALE;
  const languages = Array.isArray(navigator.languages) && navigator.languages.length
    ? navigator.languages
    : [navigator.language];

  for (const language of languages) {
    const locale = normalizeLocale(language);
    if (locale) return locale;
  }

  return DEFAULT_LOCALE;
};

browserLocale.value = detectBrowserLocale();

export const effectiveLocale = computed<SupportedLocale>(
  () => preferredLocale.value ?? browserLocale.value ?? DEFAULT_LOCALE
);

export const i18n = createI18n({
  legacy: false,
  globalInjection: true,
  locale: effectiveLocale.value,
  fallbackLocale: DEFAULT_LOCALE,
  messages,
  missingWarn: false,
  fallbackWarn: false,
});

const interpolate = (message: string, params?: Record<string, unknown>) => {
  if (!params) return message;
  return message.replace(/\{(\w+)\}/gu, (_match, key: string) => String(params[key] ?? ''));
};

const translatePatternRu = (key: string): string | null => {
  for (const [prefix, translatedPrefix] of Object.entries(ruMessages)) {
    if (!prefix.endsWith(':') || !key.startsWith(`${prefix} `)) continue;
    return `${translatedPrefix} ${key.slice(prefix.length + 1)}`;
  }

  const countedLabels: Record<string, string> = {
    Blocks: 'Блоки',
    Tools: 'Инструменты',
    'Config tags': 'Теги конфигураций',
    Variables: 'Переменные',
    Files: 'Файлы',
    'First messages': 'Первые сообщения',
  };

  const tokenLabel = (value: string) => {
    const number = Number(value.replace(/\s/gu, '').replace(',', '.'));
    if (!Number.isInteger(number)) return 'токена';

    const absolute = Math.abs(number);
    const lastTwo = absolute % 100;
    const lastOne = absolute % 10;

    if (lastTwo >= 11 && lastTwo <= 14) return 'токенов';
    if (lastOne === 1) return 'токен';
    if (lastOne >= 2 && lastOne <= 4) return 'токена';
    return 'токенов';
  };

  const memberLabel = (value: string) => {
    const number = Number(value);
    const absolute = Math.abs(number);
    const lastTwo = absolute % 100;
    const lastOne = absolute % 10;

    if (lastTwo >= 11 && lastTwo <= 14) return 'участников';
    if (lastOne === 1) return 'участник';
    if (lastOne >= 2 && lastOne <= 4) return 'участника';
    return 'участников';
  };

  const resourceLabel = (value: string, forms: [string, string, string]) => {
    const number = Number(value);
    const absolute = Math.abs(number);
    const lastTwo = absolute % 100;
    const lastOne = absolute % 10;

    if (lastTwo >= 11 && lastTwo <= 14) return forms[2];
    if (lastOne === 1) return forms[0];
    if (lastOne >= 2 && lastOne <= 4) return forms[1];
    return forms[2];
  };

  const blockLabel = (value: string) => resourceLabel(value, ['блок', 'блока', 'блоков']);
  const toolLabel = (value: string) => resourceLabel(value, ['инструмент', 'инструмента', 'инструментов']);

  const patterns: Array<[RegExp, (match: RegExpExecArray) => string]> = [
    [/^Add \((\d+)\)$/u, (match) => `${ruMessages.Add ?? 'Add'} (${match[1]})`],
    [/^(Blocks|Tools|Config tags|Variables|Files|First messages) \((\d+)\)$/u, (match) =>
      `${countedLabels[match[1]] ?? match[1]} (${match[2]})`],
    [/^(Created|Updated) (.+)$/u, (match) => `${ruMessages[match[1]] ?? match[1]} ${match[2]}`],
    [/^· (Created|Updated) (.+)$/u, (match) => `· ${ruMessages[match[1]] ?? match[1]} ${match[2]}`],
    [/^(.+ · )(Created|Updated) (.+)$/u, (match) =>
      `${match[1]}${ruMessages[match[2]] ?? match[2]} ${match[3]}`],
    [/^(\d+(?:[.,]\d+)?) tokens$/u, (match) => `${match[1]} ${tokenLabel(match[1])}`],
    [/^(\d+) members?$/u, (match) => `${match[1]} ${memberLabel(match[1])}`],
    [/^(\d+) blocks? · (\d+) tools?$/u, (match) =>
      `${match[1]} ${blockLabel(match[1])} · ${match[2]} ${toolLabel(match[2])}`],
    [/^(\d+) blocks?$/u, (match) => `${match[1]} ${blockLabel(match[1])}`],
    [/^(\d+) tools?$/u, (match) => `${match[1]} ${toolLabel(match[1])}`],
    [/^Delete tag "(.+)"\?$/u, (match) => `Удалить тег "${match[1]}"?`],
    [/^Delete user "(.+)"\?$/u, (match) => `Удалить пользователя "${match[1]}"?`],
    [/^Delete group "(.+)"\?$/u, (match) => `Удалить группу "${match[1]}"?`],
    [/^Retry from step (\d+)\? This will delete this step and all following steps for this message\.$/u, (match) =>
      `Повторить с шага ${match[1]}? Этот шаг и все последующие шаги сообщения будут удалены.`],
    [/^Copy message (\d+)$/u, (match) => `Копировать сообщение ${match[1]}`],
    [/^Edit message (\d+)$/u, (match) => `Изменить сообщение ${match[1]}`],
    [/^Delete message (\d+)$/u, (match) => `Удалить сообщение ${match[1]}`],
    [/^Download (.+)$/u, (match) => `Скачать ${match[1]}`],
    [/^Branch from message (\d+)$/u, (match) => `Ветка от сообщения ${match[1]}`],
    [/^(.+ · \d+) msgs$/u, (match) => `${match[1]} сообщ.`],
    [/^(.+ · )(\d+(?:[.,]\d+)?) tokens$/u, (match) => `${match[1]}${match[2]} ${tokenLabel(match[2])}`],
  ];

  for (const [pattern, replacer] of patterns) {
    const match = pattern.exec(key);
    if (match) return replacer(match);
  }

  return null;
};

const translatePattern = (key: string): string | null =>
  effectiveLocale.value === 'ru' ? translatePatternRu(key) : null;

export const translate = (key: string, params?: Record<string, unknown>): string => {
  const locale = effectiveLocale.value;
  const localized = locale === 'ru' ? ruMessages[key] : undefined;
  return interpolate(localized || translatePattern(key) || key, params);
};

export const translateMultiline = (value: string): string =>
  value
    .split('\n')
    .map((line) => translate(line))
    .join('\n');

export const hasTranslationKey = (key: string) => Object.prototype.hasOwnProperty.call(ruMessages, key);
export const canTranslate = (key: string) => hasTranslationKey(key) || translatePatternRu(key) !== null;
export const translationVariants = (key: string): string[] =>
  [key, ruMessages[key], translatePatternRu(key)].filter((value): value is string => Boolean(value));

export const setPreferredLocale = (value: unknown) => {
  preferredLocale.value = normalizePreferredLocale(value);
};

export const getPreferredLocale = () => preferredLocale.value;
export const getEffectiveLocale = () => effectiveLocale.value;

const applyDocumentLocale = (locale: SupportedLocale) => {
  if (typeof document !== 'undefined') {
    document.documentElement.lang = locale;
  }
};

watch(
  effectiveLocale,
  (locale) => {
    i18n.global.locale.value = locale;
    applyDocumentLocale(locale);
  },
  { immediate: true }
);
