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
const continuationCountLabel = (count: number) => `${count} continuations`;

describe('chat list relation labels', () => {
  it('provides spawn badge and secondary metadata labels', () => {
    const spawn = chat({ parent_relation_kind: 'spawn', child_handoff_count: 2 });

    expect(chatListRelationLabelKey(spawn)).toBe('Spawn');
    expect(chatListRelationMeta(spawn, translate, continuationCountLabel)).toBe(
      'Spawn · 2 continuations'
    );
  });

  it('preserves fork and handoff labels', () => {
    expect(chatListRelationLabelKey(chat({ parent_relation_kind: 'fork' }))).toBe('Fork');
    expect(chatListRelationLabelKey(chat({ parent_relation_kind: 'handoff' }))).toBe(
      'Continuation'
    );
  });

  it('suppresses relation badges and metadata when continuation navigation is present', () => {
    const spawn = chat({
      parent_relation_kind: 'spawn',
      child_handoff_count: 2,
      continuation_nav: [
        { chat_id: 1, label: '1' },
        { chat_id: 2, label: '2' },
      ],
    });

    expect(chatListRelationLabelKey(spawn)).toBeNull();
    expect(chatListRelationMeta(spawn, translate, continuationCountLabel)).toBeNull();
  });
});
