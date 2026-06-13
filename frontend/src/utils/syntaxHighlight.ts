import prismComponents from 'prismjs/components.json';

type PrismStatic = typeof import('prismjs').default;

type PrismLanguageEntry = {
  alias?: string | string[];
  require?: string | string[];
  modify?: string | string[];
};

type PrismComponents = {
  languages: Record<string, PrismLanguageEntry | string | undefined>;
};

const components = prismComponents as PrismComponents;
const languageModules = import.meta.glob([
  '../../node_modules/prismjs/components/prism-*.js',
  '!../../node_modules/prismjs/components/prism-*.min.js',
]);

const LANGUAGE_ALIASES = (() => {
  const aliases: Record<string, string> = {};

  Object.entries(components.languages).forEach(([language, entry]) => {
    if (language === 'meta' || typeof entry === 'string' || !entry) return;
    const values = Array.isArray(entry.alias) ? entry.alias : entry.alias ? [entry.alias] : [];
    values.forEach((alias) => {
      aliases[alias] = language;
    });
  });

  return aliases;
})();

const PRISM_PLAIN_TEXT_LANGUAGES = new Set(['none', 'plain', 'plaintext', 'text', 'txt']);

let prismPromise: Promise<PrismStatic> | null = null;
const loadingLanguages = new Map<string, Promise<boolean>>();
const loadedLanguages = new Set<string>();
const failedLanguages = new Set<string>();

const getCodeBlockLanguage = (codeEl: Element) => {
  for (const className of Array.from(codeEl.classList)) {
    const match = /^(?:language|lang)-(.+)$/.exec(className);
    if (!match) continue;
    const raw = match[1]?.trim().toLowerCase();
    if (!raw) continue;
    return raw;
  }
  return null;
};

const highlightedSources = new WeakMap<Element, string>();

const toArray = (value: string | string[] | undefined) => {
  if (Array.isArray(value)) return value;
  return value ? [value] : [];
};

const normalizeLanguage = (rawLanguage: string) => {
  const language = rawLanguage.trim().toLowerCase();
  return LANGUAGE_ALIASES[language] ?? language;
};

const getLanguageEntry = (language: string): PrismLanguageEntry | null => {
  const entry = components.languages[language];
  if (!entry || typeof entry === 'string') return null;
  return entry;
};

const getLanguageDependencies = (language: string) => {
  const entry = getLanguageEntry(language);
  if (!entry) return [];
  return [...toArray(entry.require), ...toArray(entry.modify)].map(normalizeLanguage);
};

const loadPrism = async () => {
  if (!prismPromise) {
    prismPromise = import('prismjs')
      .then((module) => module.default)
      .catch((error) => {
        prismPromise = null;
        throw error;
      });
  }

  return prismPromise;
};

const loadLanguageModule = async (language: string) => {
  const modulePath = `../../node_modules/prismjs/components/prism-${language}.js`;
  const importer = languageModules[modulePath];
  if (!importer) return false;

  await importer();
  return true;
};

const ensureLanguage = async (language: string): Promise<boolean> => {
  if (PRISM_PLAIN_TEXT_LANGUAGES.has(language)) return false;
  if (loadedLanguages.has(language)) return true;
  if (failedLanguages.has(language)) return false;

  const prism = await loadPrism();
  if (prism.languages[language]) {
    loadedLanguages.add(language);
    return true;
  }

  const cached = loadingLanguages.get(language);
  if (cached) return cached;

  const promise = (async () => {
    const dependencies = getLanguageDependencies(language);
    for (const dependency of dependencies) {
      await ensureLanguage(dependency);
    }

    try {
      const loaded = await loadLanguageModule(language);
      if (!loaded || !prism.languages[language]) {
        failedLanguages.add(language);
        return false;
      }

      loadedLanguages.add(language);
      return true;
    } catch {
      failedLanguages.add(language);
      return false;
    } finally {
      loadingLanguages.delete(language);
    }
  })();

  loadingLanguages.set(language, promise);
  return promise;
};

export const highlightCodeBlocks = async (root: ParentNode, options?: { highlightedAttr?: string }) => {
  const highlightedAttr = options?.highlightedAttr ?? 'data-code-highlighted';

  const blocks = Array.from(
    root.querySelectorAll('pre > code[class*="language-"], pre > code[class*="lang-"]')
  );

  await Promise.all(
    blocks.map(async (codeEl) => {
      const rawLanguage = getCodeBlockLanguage(codeEl);
      if (!rawLanguage) return;

      const language = normalizeLanguage(rawLanguage);
      const hasLanguage = await ensureLanguage(language);
      if (!hasLanguage) return;

      const prism = await loadPrism();
      const grammar = prism.languages[language];
      if (!grammar) return;

      const code = codeEl.textContent ?? '';
      if (codeEl.getAttribute(highlightedAttr) === 'true' && highlightedSources.get(codeEl) === code) {
        return;
      }

      const highlighted = prism.highlight(code, grammar, language);
      codeEl.innerHTML = highlighted;
      codeEl.setAttribute(highlightedAttr, 'true');
      highlightedSources.set(codeEl, code);

      if (language !== rawLanguage) {
        codeEl.classList.add(`language-${language}`);
      }
    })
  );
};
