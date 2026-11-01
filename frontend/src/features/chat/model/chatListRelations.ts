import type { ChatSummary } from '@/types/api';

export type ChatListRelationLabelKey = 'Fork' | 'Spawn';

type ChatListRelationFields = Pick<ChatSummary, 'parent_relation_kind'>;

export const chatListRelationLabelKey = (
  chat: ChatListRelationFields
): ChatListRelationLabelKey | null => {
  switch (chat.parent_relation_kind) {
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
  translate: (key: ChatListRelationLabelKey) => string
): string | null => {
  const labelKey = chatListRelationLabelKey(chat);
  return labelKey ? translate(labelKey) : null;
};
