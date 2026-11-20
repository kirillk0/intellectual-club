export const CHAT_SEARCH_DEBOUNCE_MS = 150;

const words = /[\p{L}\p{N}][\p{L}\p{M}\p{N}]*/gu;
const wholeWord = /^[\p{L}\p{N}][\p{L}\p{M}\p{N}]*$/u;
const graphemes = typeof Intl.Segmenter === 'function' ? new Intl.Segmenter() : null;
const encoder = new TextEncoder();
const shortQueryHint = 'Enter a word with at least 3 letters or digits.';
const longQueryHint = 'Search query is too long. Shorten the text or use fewer words.';

function isPrefix(word: string) {
  if (!graphemes) return [...word.normalize('NFC').replace(/\p{M}/gu, '')].length >= 3;
  let length = 0;
  for (const _ of graphemes.segment(word)) if (++length === 3) return true;
  return false;
}

// Keep the client in step with the MessageText parser, including its fail-closed limits.
export function parseChatSearch(text: string, ordered: boolean): { terms: string[]; hint: string | null } {
  const query = text.trim();
  if (!query) return { terms: [], hint: null };
  if (encoder.encode(query).length > 4096) return { terms: [], hint: longQueryHint };
  const tokens = (query.normalize('NFC').match(words) ?? []).map((word) => word.toLowerCase());
  if (tokens.some((word) => encoder.encode(word).length > 256)) return { terms: [], hint: longQueryHint };
  const terms = ordered ? tokens : [...new Set(tokens.filter(isPrefix))];
  if (terms.length > 16) return { terms: [], hint: longQueryHint };
  return terms.some(isPrefix) ? { terms, hint: null } : { terms: [], hint: shortQueryHint };
}

type SnippetPart = { text: string; match: boolean };

// Preserve original text and mark only matching prefixes. Ordered searches mark complete
// consecutive sequences; a short connecting word in such a sequence must match in full.
export function highlightSearchSnippet(text: string, terms: readonly string[], ordered: boolean): SnippetPart[] {
  const tokens = Array.from(text.matchAll(words));
  const patterns = terms.filter((term) => wholeWord.test(term) && (ordered || isPrefix(term)))
    .map((term) => new RegExp(`^${term}${isPrefix(term) ? '' : '$'}`, 'iu'));
  const marked = new Map<number, number>();
  const mark = (index: number, length: number) => marked.set(index, Math.max(marked.get(index) ?? 0, length));
  if (patterns.length) {
    for (let i = 0; i < tokens.length; i++) {
      if (ordered) {
        if (i + patterns.length > tokens.length) break;
        const sequence = patterns.map((pattern, j) => pattern.exec(tokens[i + j][0])?.[0]);
        if (sequence.every((part) => part !== undefined)) {
          sequence.forEach((part, j) => mark(tokens[i + j].index, part!.length));
        }
      } else {
        for (const pattern of patterns) {
          const match = pattern.exec(tokens[i][0]);
          if (match) mark(tokens[i].index, match[0].length);
        }
      }
    }
  }
  const parts: SnippetPart[] = [];
  let end = 0;
  for (const [start, length] of marked) {
    if (start > end) parts.push({ text: text.slice(end, start), match: false });
    end = start + length;
    parts.push({ text: text.slice(start, end), match: true });
  }
  if (end < text.length) parts.push({ text: text.slice(end), match: false });
  return parts;
}
