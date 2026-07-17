import type { ChatSummary } from '@/types/api';

export type ChatListRelationLabelKey = 'Continuation' | 'Fork' | 'Spawn';

type ChatListRelationFields = Pick<
  ChatSummary,
  'parent_relation_kind' | 'continuation_nav' | 'child_handoff_count'
>;

export const chatListRelationLabelKey = (
  chat: ChatListRelationFields
): ChatListRelationLabelKey | null => {
  if (Array.isArray(chat.continuation_nav) && chat.continuation_nav.length > 1) return null;

  switch (chat.parent_relation_kind) {
    case 'handoff':
      return 'Continuation';
    case 'fork':
      return 'Fork';
    case 'spawn':
      return 'Spawn';
    default:
      return null;
  }
};

export const chatListRelationMeta = (
  chat: ChatListRelationFields,
  translate: (key: ChatListRelationLabelKey) => string,
  continuationCountLabel: (count: number) => string
): string | null => {
  if (Array.isArray(chat.continuation_nav) && chat.continuation_nav.length > 1) return null;

  const parts: string[] = [];
  const labelKey = chatListRelationLabelKey(chat);
  const count = Number(chat.child_handoff_count || 0);

  if (labelKey) parts.push(translate(labelKey));
  if (count > 0) parts.push(continuationCountLabel(count));

  return parts.length ? parts.join(' · ') : null;
};
