import type {
  ChatBranchMessage,
  ChatMessageContentPart,
  ChatMessageDisplayItem,
} from '@/types/api';

export type HandoffSystemEventKind = 'handoff_request' | 'handoff_summary';

export const handoffSystemEventItemTypes = new Set<HandoffSystemEventKind>([
  'handoff_request',
  'handoff_summary',
]);

const finiteSequence = (value: number | null | undefined) =>
  typeof value === 'number' && Number.isFinite(value) ? value : 0;

export const isSteeringContentPart = (part: ChatMessageContentPart) => part.item_type === 'steering';

export const isHandoffSystemEventItemType = (
  itemType: string | null | undefined
): itemType is HandoffSystemEventKind =>
  typeof itemType === 'string' && handoffSystemEventItemTypes.has(itemType as HandoffSystemEventKind);

const inferredDisplayItems = (message: ChatBranchMessage): ChatMessageDisplayItem[] => {
  const values = [
    ...(message.content?.parts || []),
    ...(message.content?.media || []),
  ];
  const seen = new Set<string>();
  const items: ChatMessageDisplayItem[] = [];

  for (const value of values) {
    const itemType = String(value.item_type || '');
    if (!itemType) continue;
    const key = `${value.step_id ?? ''}:${value.item_id ?? ''}:${value.step_sequence ?? ''}:${value.item_sequence ?? ''}:${itemType}`;
    if (seen.has(key)) continue;
    seen.add(key);
    items.push({
      step_id: value.step_id,
      step_sequence: value.step_sequence,
      item_id: value.item_id,
      item_sequence: value.item_sequence,
      item_type: itemType,
    });
  }

  return items;
};

export const chatMessageDisplayItems = (message: ChatBranchMessage) =>
  message.content?.items?.length ? message.content.items : inferredDisplayItems(message);

export const chatMessageContainsHandoffSystemEvent = (message: ChatBranchMessage) =>
  chatMessageDisplayItems(message).some((item) => isHandoffSystemEventItemType(item.item_type));

export const chatMessageHandoffSystemEventKind = (
  message: ChatBranchMessage
): HandoffSystemEventKind | null => {
  const items = chatMessageDisplayItems(message);
  if (items.length === 0 || items.some((item) => !isHandoffSystemEventItemType(item.item_type))) {
    return null;
  }

  if (message.role === 'assistant' || items.some((item) => item.item_type === 'handoff_summary')) {
    return 'handoff_summary';
  }

  return 'handoff_request';
};

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
