import { describe, expect, it } from 'vitest';

import {
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
});
