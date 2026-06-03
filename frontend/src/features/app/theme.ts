import { computed, ref, watch } from 'vue';

export const PREFERRED_THEMES = ['system', 'light', 'dark'] as const;
export type PreferredTheme = (typeof PREFERRED_THEMES)[number];
export type EffectiveTheme = 'light' | 'dark';

const preferredThemeSet = new Set<string>(PREFERRED_THEMES);
const preferredTheme = ref<PreferredTheme>('system');
const systemTheme = ref<EffectiveTheme>('light');

export const isPreferredTheme = (value: unknown): value is PreferredTheme =>
  typeof value === 'string' && preferredThemeSet.has(value);

export const normalizePreferredTheme = (value: unknown): PreferredTheme => {
  if (typeof value !== 'string') return 'system';
  const normalized = value.trim().toLowerCase();
  return isPreferredTheme(normalized) ? normalized : 'system';
};

const detectSystemTheme = (): EffectiveTheme => {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return 'light';
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
};

systemTheme.value = detectSystemTheme();

const mediaQuery =
  typeof window !== 'undefined' && typeof window.matchMedia === 'function'
    ? window.matchMedia('(prefers-color-scheme: dark)')
    : null;

const updateSystemTheme = () => {
  systemTheme.value = mediaQuery?.matches ? 'dark' : 'light';
};

if (mediaQuery) {
  if (typeof mediaQuery.addEventListener === 'function') {
    mediaQuery.addEventListener('change', updateSystemTheme);
  } else if (typeof mediaQuery.addListener === 'function') {
    mediaQuery.addListener(updateSystemTheme);
  }
}

export const effectiveTheme = computed<EffectiveTheme>(() =>
  preferredTheme.value === 'system' ? systemTheme.value : preferredTheme.value
);

const setThemeColorMeta = (theme: EffectiveTheme) => {
  const meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');
  if (!meta) return;
  meta.content = theme === 'dark' ? '#0c0f14' : '#ffffff';
};

const applyDocumentTheme = (theme: EffectiveTheme, preferred: PreferredTheme) => {
  if (typeof document === 'undefined') return;

  const root = document.documentElement;
  root.dataset.theme = theme;
  root.dataset.preferredTheme = preferred;
  root.style.colorScheme = theme;
  setThemeColorMeta(theme);
};

export const setPreferredTheme = (value: unknown) => {
  preferredTheme.value = normalizePreferredTheme(value);
};

export const getPreferredTheme = () => preferredTheme.value;

watch(
  [effectiveTheme, preferredTheme],
  ([theme, preferred]) => applyDocumentTheme(theme, preferred),
  { immediate: true }
);
