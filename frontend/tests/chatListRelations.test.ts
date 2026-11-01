import { describe, expect, it } from 'vitest';

import {
  chatListRelationLabelKey,
  chatListRelationMeta,
} from '@/features/chat/model/chatListRelations';
import type { ChatSummary } from '@/types/api';

const chat = (overrides: Partial<ChatSummary> = {}): ChatSummary => ({
  id: 1,
  note: 'Subchat',
  bot_id: null,
  bot_name: '',
  created_at: null,
  last_activity_at: null,
  ...overrides,
});

const translate = (key: string) => key;
describe('chat list relation labels', () => {
  it.each([
    ['fork', 'Fork'],
    ['spawn', 'Spawn'],
  ] as const)('provides the %s badge and secondary metadata', (kind, label) => {
    const related = chat({ parent_relation_kind: kind });

    expect(chatListRelationLabelKey(related)).toBe(label);
    expect(chatListRelationMeta(related, translate)).toBe(label);
  });

  it('omits relation labels for independent chats', () => {
    expect(chatListRelationLabelKey(chat())).toBeNull();
    expect(chatListRelationMeta(chat(), translate)).toBeNull();
  });
});
