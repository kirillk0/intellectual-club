import Prism from 'prismjs';
import 'prismjs/components/prism-bash';
import 'prismjs/components/prism-css';
import 'prismjs/components/prism-elixir';
import 'prismjs/components/prism-javascript';
import 'prismjs/components/prism-json';
import 'prismjs/components/prism-markup';
import 'prismjs/components/prism-python';
import 'prismjs/components/prism-sql';
import 'prismjs/components/prism-toml';
import 'prismjs/components/prism-typescript';
import 'prismjs/components/prism-yaml';

const LANGUAGE_ALIASES: Record<string, string> = {
  bash: 'bash',
  css: 'css',
  elixir: 'elixir',
  html: 'markup',
  javascript: 'javascript',
  js: 'javascript',
  json: 'json',
  markup: 'markup',
  python: 'python',
  py: 'python',
  sh: 'bash',
  shell: 'bash',
  sql: 'sql',
  toml: 'toml',
  ts: 'typescript',
  typescript: 'typescript',
  xml: 'markup',
  yaml: 'yaml',
  yml: 'yaml',
};

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

export const highlightCodeBlocks = (root: ParentNode, options?: { highlightedAttr?: string }) => {
  const highlightedAttr = options?.highlightedAttr ?? 'data-code-highlighted';

  const blocks = Array.from(
    root.querySelectorAll('pre > code[class*="language-"], pre > code[class*="lang-"]')
  );

  blocks.forEach((codeEl) => {
    const rawLanguage = getCodeBlockLanguage(codeEl);
    if (!rawLanguage) return;

    const language = LANGUAGE_ALIASES[rawLanguage] ?? rawLanguage;
    const grammar = (Prism.languages as Record<string, Prism.Grammar | undefined>)[language];
    if (!grammar) return;

    const code = codeEl.textContent ?? '';
    if (codeEl.getAttribute(highlightedAttr) === 'true' && highlightedSources.get(codeEl) === code) {
      return;
    }

    const highlighted = Prism.highlight(code, grammar, language);
    codeEl.innerHTML = highlighted;
    codeEl.setAttribute(highlightedAttr, 'true');
    highlightedSources.set(codeEl, code);

    if (language !== rawLanguage) {
      codeEl.classList.add(`language-${language}`);
    }
  });
};
