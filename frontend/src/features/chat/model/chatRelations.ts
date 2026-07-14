import type { ChatRelationSummary } from '@/types/api';

export type ChatRelationGenerationState = 'generating' | 'canceled' | 'error' | null;

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

export const fallbackChildRelationsForBranch = (
  relations: ChatRelationSummary[],
  messageIds: Array<number | null | undefined>
): ChatRelationSummary[] => {
  const activeMessageIds = new Set(
    messageIds.filter((messageId): messageId is number => Number.isInteger(messageId))
  );

  return relations.filter(
    (relation) =>
      !Number.isInteger(relation.message_id) || activeMessageIds.has(relation.message_id as number)
  );
};

export const childRelationGenerationState = (
  relation: ChatRelationSummary
): ChatRelationGenerationState => {
  if (typeof relation.active_generation_message_id === 'number') return 'generating';
  if (relation.last_message_status === 'canceled') return 'canceled';
  return relation.last_message_status === 'error' ? 'error' : null;
};
