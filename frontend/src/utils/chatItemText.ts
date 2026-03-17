import type { ChatMessageContent } from '@/types/api';

const sortBySequence = <T extends { sequence?: number | null }>(a: T, b: T) => {
  const aSeq = typeof a.sequence === 'number' && Number.isFinite(a.sequence) ? a.sequence : 0;
  const bSeq = typeof b.sequence === 'number' && Number.isFinite(b.sequence) ? b.sequence : 0;
  return aSeq - bSeq;
};

const textParts = (contents: ChatMessageContent[] | null | undefined) => {
  const list = (contents || []).slice().sort(sortBySequence);
  return list
    .filter((content) => content?.kind === 'text' && content.content_text)
    .map((content) => String(content.content_text ?? ''));
};

const shouldInsertReasoningBreak = (left: string, right: string) => {
  if (left === '' || right === '') return false;
  if (/\n\s*$/.test(left)) return false;
  if (/^\s*\n/.test(right)) return false;
  return true;
};

export const joinItemTextContents = (
  itemType: string | null | undefined,
  contents: ChatMessageContent[] | null | undefined
) => {
  const parts = textParts(contents);
  if (!parts.length) return '';
  if (parts.length === 1) return parts[0];

  if (itemType !== 'reasoning') {
    return parts.join('');
  }

  return parts.reduce((acc, part) => {
    if (acc === '') return part;
    return shouldInsertReasoningBreak(acc, part) ? `${acc}\n\n${part}` : `${acc}${part}`;
  }, '');
};
