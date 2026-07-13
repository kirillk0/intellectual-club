import type { ChatRelationSummary } from '@/types/api';

export const hasPositionedForkAnchor = (relation?: ChatRelationSummary | null) =>
  relation?.kind === 'fork' &&
  Number.isInteger(relation.anchor_message_id) &&
  Number.isInteger(relation.anchor_tool_call_item_id) &&
  Number.isInteger(relation.anchor_step_sequence) &&
  Number.isInteger(relation.anchor_item_sequence);

export const parentForkRelationForMessage = (
  relation: ChatRelationSummary | null,
  messageId?: number | null
): ChatRelationSummary | null => {
  if (!messageId || !hasPositionedForkAnchor(relation)) return null;
  return relation?.anchor_message_id === messageId ? relation : null;
};

export const parentRelationBannerForBranch = (
  relation: ChatRelationSummary | null,
  messageIds: Array<number | null | undefined>
): ChatRelationSummary | null => {
  if (!relation) return null;

  return messageIds.some((messageId) => parentForkRelationForMessage(relation, messageId))
    ? null
    : relation;
};
