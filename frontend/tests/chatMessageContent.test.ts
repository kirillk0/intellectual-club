import {
  chatMessageContainsHandoffSystemEvent,
  chatMessageHandoffSystemEventKind,
  fullChatMessageText,
  isHandoffContextItemType,
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
        items: [],
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
        items: [],
        parts: [part(1, 'first answer', 'answer', 1, 1), steering, part(3, 'final answer', 'answer', 2, 1)],
        media: [],
      },
    };

    expect(isSteeringContentPart(steering)).toBe(true);
    expect(primaryChatMessageText(message)).toBe('final answer');
    expect(fullChatMessageText(message)).toBe('first answer\n\nfinal answer');
  });

  it('classifies messages using display items while ignoring hidden operational items', () => {
    const request: ChatBranchMessage = {
      id: 11,
      role: 'user',
      status: 'done',
      content: {
        items: [
          {
            step_id: 1,
            step_sequence: 1,
            item_id: 2,
            item_sequence: 1,
            item_type: 'handoff_request',
          },
        ],
        parts: [part(1, 'Prepare the handoff', 'handoff_request', 1, 1)],
        media: [],
      },
      steps: [
        {
          id: 1,
          sequence: 1,
          status: 'done',
          items: [
            { id: 1, sequence: 1, type: 'reasoning', contents: [] },
            { id: 2, sequence: 2, type: 'tool_call', contents: [] },
          ],
        },
      ],
    };

    expect(chatMessageContainsHandoffSystemEvent(request)).toBe(true);
    expect(chatMessageHandoffSystemEventKind(request)).toBe('handoff_request');
  });

  it('keeps user input and mixed display items in the ordinary message UI', () => {
    const context: ChatBranchMessage = {
      id: 12,
      role: 'user',
      status: 'done',
      content: {
        items: [
          {
            step_id: 1,
            step_sequence: 1,
            item_id: 1,
            item_sequence: 1,
            item_type: 'input',
          },
        ],
        parts: [part(1, 'Continue here', 'input', 1, 1)],
        media: [],
      },
    };

    const mixed: ChatBranchMessage = {
      ...context,
      id: 13,
      content: {
        items: [
          {
            step_id: 1,
            step_sequence: 1,
            item_id: 1,
            item_sequence: 1,
            item_type: 'input',
          },
          {
            step_id: 1,
            step_sequence: 1,
            item_id: 2,
            item_sequence: 2,
            item_type: 'handoff_request',
          },
        ],
        parts: [
          part(1, 'Ordinary input', 'input', 1, 1),
          part(2, 'Prepare the handoff', 'handoff_request', 1, 2),
        ],
        media: [],
      },
    };

    expect(chatMessageContainsHandoffSystemEvent(context)).toBe(false);
    expect(chatMessageHandoffSystemEventKind(context)).toBeNull();
    expect(chatMessageContainsHandoffSystemEvent(mixed)).toBe(true);
    expect(chatMessageHandoffSystemEventKind(mixed)).toBeNull();
  });

  it('keeps answers and repeated checkpoint pairs in timeline order when copying all', () => {
    const message: ChatBranchMessage = {
      id: 15, role: 'assistant', status: 'done',
      content: {
        items: [], media: [], parts: [
          part(7, 'Final answer', 'answer', 3, 1),
          part(6, 'Second summary', 'handoff_message', 2, 3),
          part(5, 'Second history', 'handoff_history', 2, 2),
          part(4, 'Middle answer', 'answer', 2, 1),
          part(3, 'First summary', 'handoff_message', 1, 3),
          part(2, 'First history', 'handoff_history', 1, 2),
          part(1, 'First answer', 'answer', 1, 1),
        ],
      },
    };

    expect(primaryChatMessageText(message)).toBe('Final answer');
    expect(fullChatMessageText(message)).toBe([
      'First answer', 'History', 'First history', 'Context summary', 'First summary',
      'Middle answer', 'History', 'Second history', 'Context summary', 'Second summary', 'Final answer',
    ].join('\n\n'));
    expect(chatMessageHandoffSystemEventKind(message)).toBeNull();
  });

  it('copies the handoff message first and both structured sections when copying all', () => {
    const message: ChatBranchMessage = {
      id: 14,
      role: 'user',
      status: 'done',
      content: {
        items: [],
        parts: [
          part(1, 'Original request', 'handoff_history', 1, 1),
          part(2, 'Earlier answer', 'handoff_history', 1, 1),
          part(3, 'Transfer summary', 'handoff_message', 1, 2),
        ],
        media: [],
      },
    };

    expect(isHandoffContextItemType('handoff_history')).toBe(true);
    expect(isHandoffContextItemType('handoff_message')).toBe(true);
    expect(isHandoffContextItemType('input')).toBe(false);
    expect(primaryChatMessageText(message)).toBe('Transfer summary');
    expect(fullChatMessageText(message)).toBe(
      'History\n\nOriginal request\n\nEarlier answer\n\nContext summary\n\nTransfer summary'
    );
  });
});
