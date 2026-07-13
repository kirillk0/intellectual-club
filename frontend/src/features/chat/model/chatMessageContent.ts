import type { ChatBranchMessage, ChatMessageContentPart } from '@/types/api';

const finiteSequence = (value: number | null | undefined) =>
  typeof value === 'number' && Number.isFinite(value) ? value : 0;

export const isSteeringContentPart = (part: ChatMessageContentPart) => part.item_type === 'steering';

export const compareChatMessageContentParts = (
  left: ChatMessageContentPart,
  right: ChatMessageContentPart
) => {
  const fields: Array<keyof ChatMessageContentPart> = [
    'step_sequence',
    'item_sequence',
    'sequence',
    'content_id',
  ];

  for (const field of fields) {
    const difference = finiteSequence(left[field] as number | null | undefined) -
      finiteSequence(right[field] as number | null | undefined);
    if (difference !== 0) return difference;
  }

  return 0;
};

export const sortedChatMessageContentParts = (message: ChatBranchMessage) =>
  [...(message.content?.parts || [])].sort(compareChatMessageContentParts);

const primaryChatMessageTexts = (message: ChatBranchMessage) =>
  sortedChatMessageContentParts(message)
    .filter((part) => message.role !== 'assistant' || !isSteeringContentPart(part))
    .map((part) => String(part.text ?? ''))
    .filter((text) => text.trim() !== '');

export const primaryChatMessageText = (message: ChatBranchMessage) =>
  primaryChatMessageTexts(message).at(-1) ?? '';

export const fullChatMessageText = (message: ChatBranchMessage) =>
  primaryChatMessageTexts(message).join('\n\n');
