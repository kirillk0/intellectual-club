import { mount } from '@vue/test-utils';

import ChatMessageBubble from '@/components/chat/ChatMessageBubble.vue';
import { setPreferredLocale } from '@/i18n';
import type { ChatBranchMessage, ChatRelationSummary } from '@/types/api';

describe('ChatMessageBubble fork timeline', () => {
  beforeEach(() => {
    setPreferredLocale('en');
  });

  afterEach(() => {
    setPreferredLocale(null);
  });

  it('renders a fork between answer items at the originating tool call position', () => {
    const message: ChatBranchMessage = {
      id: 10,
      role: 'assistant',
      status: 'done',
      content: {
        parts: [
          {
            content_id: 2,
            sequence: 1,
            text: 'After the fork',
            item_type: 'answer',
            step_sequence: 1,
            item_sequence: 3,
          },
          {
            content_id: 1,
            sequence: 1,
            text: 'Before the fork',
            item_type: 'answer',
            step_sequence: 1,
            item_sequence: 1,
          },
        ],
        media: [],
      },
    };

    const fork: ChatRelationSummary = {
      chat_id: 20,
      kind: 'fork',
      note: 'Investigate independently',
      parent_tool_call_item_id: 30,
      parent_step_sequence: 1,
      parent_item_sequence: 2,
    };

    const wrapper = mount(ChatMessageBubble, {
      props: {
        message,
        index: 0,
        forkRelations: [fork],
      },
      global: {
        stubs: {
          RouterLink: {
            template: '<a><slot /></a>',
          },
        },
      },
    });

    const entries = wrapper.get('.message-content').findAll(
      ':scope > .message-answer-part, :scope > .message-fork-card'
    );

    expect(entries).toHaveLength(3);
    expect(entries[0]?.text()).toContain('Before the fork');
    expect(entries[1]?.classes()).toContain('message-fork-card');
    expect(entries[1]?.text()).toContain('Investigate independently');
    expect(entries[2]?.text()).toContain('After the fork');
  });
});
