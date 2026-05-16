import DOMPurify from 'dompurify';
import { marked } from 'marked';
import Temml, { type Options as TemmlOptions } from 'temml';

import { highlightCodeBlocks } from './syntaxHighlight';

marked.setOptions({ breaks: true });

type MathDelimiter = {
  left: string;
  right: string;
  display: boolean;
  preserveDelimiters?: boolean;
  isValidStart?: (text: string, index: number) => boolean;
  isValidEnd?: (text: string, index: number) => boolean;
};

type MathSegment =
  | { type: 'text'; value: string }
  | { type: 'math'; value: string; raw: string; display: boolean };

type TemmlAutoRenderOptions = TemmlOptions & {
  macros?: Record<string, unknown>;
};

type PreparedMarkdownMath = {
  markdown: string;
  placeholders: Map<string, Extract<MathSegment, { type: 'math' }>>;
};

const isWhitespace = (value: string | undefined) => value != null && /\s/u.test(value);

const isDigit = (value: string | undefined) => value != null && /\d/u.test(value);

const isEscaped = (text: string, index: number) => {
  let backslashCount = 0;
  let cursor = index - 1;

  while (cursor >= 0 && text[cursor] === '\\') {
    backslashCount += 1;
    cursor -= 1;
  }

  return backslashCount % 2 === 1;
};

const DOLLAR_DELIMITER: MathDelimiter = {
  left: '$',
  right: '$',
  display: false,
  isValidStart: (text, index) => {
    const prev = text[index - 1];
    const next = text[index + 1];
    return !isWhitespace(next) && !isDigit(prev);
  },
  isValidEnd: (text, index) => {
    const prev = text[index - 1];
    const next = text[index + 1];
    return !isWhitespace(prev) && !isDigit(next);
  },
};

const MATH_DELIMITERS: MathDelimiter[] = [
  { left: '$$', right: '$$', display: true },
  { left: '\\[', right: '\\]', display: true },
  { left: '\\(', right: '\\)', display: false },
  { left: '\\begin{equation}', right: '\\end{equation}', display: true, preserveDelimiters: true },
  { left: '\\begin{equation*}', right: '\\end{equation*}', display: true, preserveDelimiters: true },
  { left: '\\begin{align}', right: '\\end{align}', display: true, preserveDelimiters: true },
  { left: '\\begin{align*}', right: '\\end{align*}', display: true, preserveDelimiters: true },
  { left: '\\begin{alignat}', right: '\\end{alignat}', display: true, preserveDelimiters: true },
  { left: '\\begin{alignat*}', right: '\\end{alignat*}', display: true, preserveDelimiters: true },
  { left: '\\begin{gather}', right: '\\end{gather}', display: true, preserveDelimiters: true },
  { left: '\\begin{gather*}', right: '\\end{gather*}', display: true, preserveDelimiters: true },
  { left: '\\begin{CD}', right: '\\end{CD}', display: true, preserveDelimiters: true },
  { left: '\\ref{', right: '}', display: false, preserveDelimiters: true },
  { left: '\\eqref{', right: '}', display: false, preserveDelimiters: true },
  DOLLAR_DELIMITER,
];

const TEMML_RENDER_OPTIONS: TemmlAutoRenderOptions = {
  throwOnError: true,
  strict: false,
};

const normalizeChatMarkdown = (input: string) => {
  const lines = input.split(/\r?\n/);

  let inFence = false;
  let fenceChar: '`' | '~' | null = null;
  let fenceLen = 0;

  const normalized = lines.map((line) => {
    const fenceMatch = /^\s*([`~]{3,})/.exec(line);
    if (fenceMatch) {
      const marker = fenceMatch[1] ?? '';
      const char = marker[0] as '`' | '~';
      const len = marker.length;

      if (!inFence) {
        inFence = true;
        fenceChar = char;
        fenceLen = len;
      } else if (fenceChar === char && len >= fenceLen) {
        inFence = false;
        fenceChar = null;
        fenceLen = 0;
      }

      return line;
    }

    if (inFence) return line;

    return line.replace(/^(\s{0,3})(#{1,6})(?=[^\s#])/, '$1$2 ');
  });

  return normalized.join('\n');
};

const SANITIZE_OPTIONS = {
  USE_PROFILES: { html: true, mathMl: true },
  FORBID_TAGS: [
    'style',
    'link',
    'meta',
    'base',
    'iframe',
    'object',
    'embed',
    'portal',
    'frame',
    'frameset',
  ],
  FORBID_ATTR: ['style', 'srcset', 'formaction'],
} as const;

const findNextMathDelimiter = (text: string, startIndex: number) => {
  for (let index = startIndex; index < text.length; index += 1) {
    const marker = text[index];
    if (marker !== '$' && marker !== '\\') continue;

    for (const delimiter of MATH_DELIMITERS) {
      if (!text.startsWith(delimiter.left, index)) continue;
      if (isEscaped(text, index)) continue;
      if (delimiter.isValidStart && !delimiter.isValidStart(text, index)) continue;
      return { delimiter, index };
    }
  }

  return null;
};

const findMathEnd = (text: string, delimiter: MathDelimiter, startIndex: number) => {
  let index = startIndex;
  let braceLevel = 0;

  while (index < text.length) {
    const char = text[index];

    if (
      braceLevel <= 0 &&
      text.startsWith(delimiter.right, index) &&
      !isEscaped(text, index) &&
      (!delimiter.isValidEnd || delimiter.isValidEnd(text, index))
    ) {
      return index;
    }

    if (char === '\\') {
      index += 2;
      continue;
    }

    if (char === '{') braceLevel += 1;
    if (char === '}') braceLevel -= 1;

    index += 1;
  }

  return -1;
};

const splitTextIntoMathSegments = (text: string): MathSegment[] => {
  const segments: MathSegment[] = [];
  let cursor = 0;

  while (cursor < text.length) {
    const next = findNextMathDelimiter(text, cursor);
    if (!next) {
      segments.push({ type: 'text', value: text.slice(cursor) });
      break;
    }

    if (next.index > cursor) {
      segments.push({ type: 'text', value: text.slice(cursor, next.index) });
    }

    const mathStart = next.index + next.delimiter.left.length;
    const mathEnd = findMathEnd(text, next.delimiter, mathStart);

    if (mathEnd === -1) {
      segments.push({ type: 'text', value: next.delimiter.left });
      cursor = mathStart;
      continue;
    }

    const raw = text.slice(next.index, mathEnd + next.delimiter.right.length);
    const value = next.delimiter.preserveDelimiters
      ? raw
      : text.slice(mathStart, mathEnd);

    segments.push({
      type: 'math',
      value,
      raw,
      display: next.delimiter.display,
    });

    cursor = mathEnd + next.delimiter.right.length;
  }

  if (!segments.length) return [{ type: 'text', value: text }];
  return segments;
};

const escapeRegex = (value: string) => value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');

const prepareMarkdownMath = (input: string): PreparedMarkdownMath => {
  const segments = splitTextIntoMathSegments(input);
  const placeholders = new Map<string, Extract<MathSegment, { type: 'math' }>>();
  let placeholderIndex = 0;

  const markdown = segments
    .map((segment) => {
      if (segment.type === 'text') return segment.value;

      const placeholder = `ICTEXPLACEHOLDER${placeholderIndex}IC`;
      placeholderIndex += 1;
      placeholders.set(placeholder, segment);
      return placeholder;
    })
    .join('');

  return { markdown, placeholders };
};

const appendRenderedMath = (
  fragment: DocumentFragment,
  segment: Extract<MathSegment, { type: 'math' }>,
  macros: Record<string, unknown>
) => {
  try {
    const rendered = Temml.renderToString(segment.value, {
      ...TEMML_RENDER_OPTIONS,
      displayMode: segment.display,
      macros,
    });
    const template = document.createElement('template');
    template.innerHTML = rendered;
    fragment.appendChild(template.content.cloneNode(true));
  } catch {
    fragment.append(document.createTextNode(segment.raw));
  }
};

const replaceMathPlaceholders = (
  root: HTMLElement,
  placeholders: Map<string, Extract<MathSegment, { type: 'math' }>>
) => {
  if (!placeholders.size) return;

  const tokenPattern = new RegExp(
    Array.from(placeholders.keys())
      .map((token) => escapeRegex(token))
      .join('|'),
    'gu'
  );

  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const targets: Text[] = [];

  while (walker.nextNode()) {
    const node = walker.currentNode as Text;
    tokenPattern.lastIndex = 0;
    if (tokenPattern.test(node.data)) targets.push(node);
  }

  const macros: Record<string, unknown> = {};

  targets.forEach((textNode) => {
    const parent = textNode.parentElement;
    const keepRaw = Boolean(parent?.closest('pre, code, script, style, textarea, option'));
    const fragment = document.createDocumentFragment();
    let lastIndex = 0;
    tokenPattern.lastIndex = 0;

    let match: RegExpExecArray | null;
    // eslint-disable-next-line no-cond-assign
    while ((match = tokenPattern.exec(textNode.data)) !== null) {
      const token = match[0];
      const start = match.index;
      const end = start + token.length;
      const segment = placeholders.get(token);

      if (start > lastIndex) {
        fragment.append(document.createTextNode(textNode.data.slice(lastIndex, start)));
      }

      if (!segment) {
        fragment.append(document.createTextNode(token));
      } else if (keepRaw) {
        fragment.append(document.createTextNode(segment.raw));
      } else {
        appendRenderedMath(fragment, segment, macros);
      }

      lastIndex = end;
    }

    if (lastIndex < textNode.data.length) {
      fragment.append(document.createTextNode(textNode.data.slice(lastIndex)));
    }

    textNode.replaceWith(fragment);
  });

  try {
    Temml.postProcess(root);
  } catch {
    // Keep rendered output even if post-processing fails.
  }
};

const renderTexExpressions = (root: HTMLElement) => {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const targets: Text[] = [];

  while (walker.nextNode()) {
    const node = walker.currentNode as Text;
    const parent = node.parentElement;
    if (!parent) continue;
    if (parent.closest('pre, code, script, style, textarea, option, math')) continue;
    if (!node.data.includes('$') && !node.data.includes('\\')) continue;
    targets.push(node);
  }

  const macros: Record<string, unknown> = {};

  targets.forEach((textNode) => {
    const segments = splitTextIntoMathSegments(textNode.data);
    if (!segments.some((segment) => segment.type === 'math')) return;

    const fragment = document.createDocumentFragment();
    segments.forEach((segment) => {
      if (segment.type === 'text') {
        fragment.append(document.createTextNode(segment.value));
        return;
      }

      appendRenderedMath(fragment, segment, macros);
    });

    textNode.replaceWith(fragment);
  });

  try {
    Temml.postProcess(root);
  } catch {
    // Keep rendered output even if post-processing fails.
  }
};

const highlightQuotes = (root: HTMLElement) => {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const pattern = /(«[^»]+»|“[^”]+”|"[^"]+")/g;

  const targets: Text[] = [];
  while (walker.nextNode()) {
    const node = walker.currentNode as Text;
    const parent = node.parentElement;
    if (parent?.closest('pre, code, math')) continue;
    pattern.lastIndex = 0;
    if (pattern.test(node.data)) targets.push(node);
  }

  targets.forEach((textNode) => {
    const text = textNode.data;
    const fragment = document.createDocumentFragment();
    let lastIndex = 0;
    pattern.lastIndex = 0;

    let match: RegExpExecArray | null;
    // eslint-disable-next-line no-cond-assign
    while ((match = pattern.exec(text)) !== null) {
      const [full] = match;
      const start = match.index;
      const end = start + full.length;

      if (start > lastIndex) {
        fragment.append(document.createTextNode(text.slice(lastIndex, start)));
      }

      const span = document.createElement('span');
      span.className = 'quote-highlight';
      span.textContent = full;
      fragment.append(span);

      lastIndex = end;
    }

    if (lastIndex < text.length) {
      fragment.append(document.createTextNode(text.slice(lastIndex)));
    }

    textNode.replaceWith(fragment);
  });
};

const wrapTables = (html: string) => {
  if (!html.includes('<table')) return html;
  const doc = new DOMParser().parseFromString(html, 'text/html');
  doc.querySelectorAll('table').forEach((table) => {
    if (table.closest('.table-scroll')) return;
    const wrapper = doc.createElement('div');
    wrapper.className = 'table-scroll';
    table.parentNode?.insertBefore(wrapper, table);
    wrapper.appendChild(table);
  });
  return doc.body.innerHTML;
};

const addCodeCopyButtons = (root: HTMLElement) => {
  root.querySelectorAll('pre > code').forEach((code) => {
    const pre = code.parentElement;
    if (!pre || pre.parentElement?.classList.contains('code-copy-block')) return;

    const wrapper = document.createElement('div');
    wrapper.className = 'code-copy-block';

    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'code-copy-button';
    button.setAttribute('data-code-copy-button', 'true');
    button.setAttribute('aria-label', 'Copy code');
    button.setAttribute('title', 'Copy code');

    pre.parentNode?.insertBefore(wrapper, pre);
    wrapper.append(button, pre);
  });
};

export const renderChatMessageHtml = (
  content: string | null | undefined,
  options?: { highlightCode?: boolean; codeCopyButtons?: boolean }
) => {
  const raw = content == null || content === '' ? '…' : content;
  const prepared = prepareMarkdownMath(raw);
  const normalized = normalizeChatMarkdown(prepared.markdown);
  const html = marked.parse(normalized) as string;
  const wrapper = document.createElement('div');
  wrapper.innerHTML = html;

  if (options?.highlightCode) {
    highlightCodeBlocks(wrapper);
  }

  replaceMathPlaceholders(wrapper, prepared.placeholders);
  renderTexExpressions(wrapper);
  highlightQuotes(wrapper);
  if (options?.codeCopyButtons) {
    addCodeCopyButtons(wrapper);
  }

  const sanitized = DOMPurify.sanitize(wrapper.innerHTML, SANITIZE_OPTIONS);
  return wrapTables(sanitized);
};
