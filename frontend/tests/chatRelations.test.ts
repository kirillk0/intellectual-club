import { describe, expect, it } from 'vitest';

import {
  childRelationGenerationState,
  fallbackChildRelationsForBranch,
  parentForkRelationForMessage,
  parentRelationBannerForBranch,
} from '@/features/chat/model/chatRelations';
import type { ChatRelationSummary } from '@/types/api';

const positionedParent: ChatRelationSummary = {
  chat_id: 5,
  kind: 'fork',
  anchor_message_id: 10,
  anchor_tool_call_item_id: 40,
  anchor_step_sequence: 1,
  anchor_item_sequence: 2,
};

describe('chat relation positioning', () => {
  it('positions a fork parent only in its anchored message', () => {
    expect(parentForkRelationForMessage(positionedParent, 10)).toBe(positionedParent);
    expect(parentForkRelationForMessage(positionedParent, 11)).toBeNull();
  });

  it('positions a spawn child at its source tool call anchor', () => {
    const spawn = { ...positionedParent, chat_id: 6, kind: 'spawn' };

    expect(parentForkRelationForMessage(spawn, 10)).toBe(spawn);
    expect(parentRelationBannerForBranch(spawn, [9, 10, 11])).toBeNull();
  });

  it('keeps an unanchored spawn parent as a top banner', () => {
    const spawnParent: ChatRelationSummary = {
      chat_id: 6,
      kind: 'spawn',
      anchor_message_id: null,
      anchor_tool_call_item_id: null,
      anchor_step_sequence: null,
      anchor_item_sequence: null,
    };

    expect(parentRelationBannerForBranch(spawnParent, [9, 10, 11])).toBe(spawnParent);
  });

  it('hides the parent banner only when the inline anchor is on the active branch', () => {
    expect(parentRelationBannerForBranch(positionedParent, [9, 10, 11])).toBeNull();
    expect(parentRelationBannerForBranch(positionedParent, [9, 11])).toBe(positionedParent);
  });

  it('keeps the parent banner when a fork anchor is incomplete or the relation is a handoff', () => {
    const incomplete = { ...positionedParent, anchor_tool_call_item_id: null };
    const handoff = { ...positionedParent, kind: 'handoff' };

    expect(parentRelationBannerForBranch(incomplete, [10])).toBe(incomplete);
    expect(parentRelationBannerForBranch(handoff, [10])).toBe(handoff);
  });

  it('hides fallback child relations attached to inactive branch messages', () => {
    const activeRelation: ChatRelationSummary = { chat_id: 20, message_id: 10 };
    const inactiveRelation: ChatRelationSummary = { chat_id: 21, message_id: 11 };
    const unpositionedRelation: ChatRelationSummary = { chat_id: 22, message_id: null };

    expect(
      fallbackChildRelationsForBranch(
        [activeRelation, inactiveRelation, unpositionedRelation],
        [9, 10]
      )
    ).toEqual([activeRelation, unpositionedRelation]);
  });

  it('maps canceled child generation to a distinct canceled state', () => {
    expect(
      childRelationGenerationState({ chat_id: 20, last_message_status: 'canceled' })
    ).toBe('canceled');
  });

  it('keeps a handed-off child generating when its source message is done', () => {
    expect(
      childRelationGenerationState({
        chat_id: 20,
        active_generation_message_id: 42,
        last_message_status: 'done',
      })
    ).toBe('generating');
  });
});
