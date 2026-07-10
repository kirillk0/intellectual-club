import {
  isSteeringContentPart,
  primaryChatMessageText,
  sortedChatMessageContentParts,
} from '@/features/chat/model/chatMessageContent';
import type { ChatBranchMessage, ChatMessageContentPart } from '@/types/api';

const part = (
  contentId: number,
  text: string,
  itemType: string,
  stepSequence: number,
  itemSequence: number
): ChatMessageContentPart => ({
  content_id: contentId,
  sequence: 0,
  text,
  item_type: itemType,
  step_sequence: stepSequence,
  item_sequence: itemSequence,
});

describe('chat message content', () => {
  it('sorts answer and steering parts by their step and item positions', () => {
    const message: ChatBranchMessage = {
      id: 10,
      role: 'assistant',
      status: 'done',
      content: {
        parts: [
          part(3, 'after', 'answer', 2, 1),
          part(2, 'correction', 'steering', 1, 2),
          part(1, 'before', 'answer', 1, 1),
        ],
        media: [],
      },
    };

    expect(sortedChatMessageContentParts(message).map((item) => item.content_id)).toEqual([1, 2, 3]);
  });

  it('excludes steering text from assistant copy and edit text', () => {
    const steering = part(2, 'do not copy me', 'steering', 1, 2);
    const message: ChatBranchMessage = {
      id: 10,
      role: 'assistant',
      status: 'done',
      content: {
        parts: [part(1, 'first answer', 'answer', 1, 1), steering, part(3, 'final answer', 'answer', 2, 1)],
        media: [],
      },
    };

    expect(isSteeringContentPart(steering)).toBe(true);
    expect(primaryChatMessageText(message)).toBe('final answer');
  });
});
