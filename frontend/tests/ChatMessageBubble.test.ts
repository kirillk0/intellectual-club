import { mount } from '@vue/test-utils';

import ChatMessageBubble from '@/components/chat/ChatMessageBubble.vue';
import { setPreferredLocale } from '@/i18n';
import type { ChatBranchMessage, ChatRelationSummary } from '@/types/api';

const handoffMessage = (
  id: number,
  role: 'user' | 'assistant',
  itemType: 'handoff_request' | 'handoff_summary' | 'handoff_context',
  text: string,
  status: ChatBranchMessage['status'] = 'done'
): ChatBranchMessage => ({
  id,
  role,
  status,
  content: {
    items: [
      {
        step_id: id * 10,
        step_sequence: 1,
        item_id: id * 100,
        item_sequence: 1,
        item_type: itemType,
      },
    ],
    parts: text
      ? [
          {
            content_id: id * 1000,
            sequence: 1,
            text,
            item_type: itemType,
            step_id: id * 10,
            step_sequence: 1,
            item_id: id * 100,
            item_sequence: 1,
          },
        ]
      : [],
    media: [],
  },
});

describe('ChatMessageBubble fork timeline', () => {
  beforeEach(() => {
    setPreferredLocale('en');
  });

  afterEach(() => {
    setPreferredLocale(null);
    document.body.innerHTML = '';
  });

  it('renders a fork between answer items at the originating tool call position', () => {
    const message: ChatBranchMessage = {
      id: 10,
      role: 'assistant',
      status: 'done',
      content: {
        items: [],
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
            created_at: '2026-07-23T10:15:00Z',
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
      anchor_message_id: 10,
      anchor_tool_call_item_id: 30,
      anchor_step_sequence: 1,
      anchor_item_sequence: 2,
      created_at: '2026-07-23T10:16:00Z',
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
      ':scope > .message-answer-part, :scope > .message-fork-entry'
    );

    expect(entries).toHaveLength(3);
    expect(entries[0]?.text()).toContain('Before the fork');
    expect(entries[0]?.get('.message-answer-time').text()).toMatch(/^\d{2}:\d{2} · 1$/);
    expect(entries[1]?.get('.message-fork-card').text()).toContain('Investigate independently');
    expect(
      entries[1]?.get(':scope > .message-fork-card + .message-fork-entry__meta').text()
    ).toMatch(/^\d{2}:\d{2} · 1$/);
    expect(entries[1]?.get('.message-fork-card').find('.message-fork-entry__meta').exists()).toBe(false);
    expect(entries[2]?.text()).toContain('After the fork');

    wrapper.unmount();
  });

  it('renders a parent fork link at the mirrored tool call position', () => {
    const message: ChatBranchMessage = {
      id: 10,
      role: 'assistant',
      status: 'done',
      content: {
        items: [],
        parts: [
          {
            content_id: 2,
            sequence: 1,
            text: 'Child answer',
            item_type: 'answer',
            step_sequence: 2,
            item_sequence: 1,
          },
          {
            content_id: 1,
            sequence: 1,
            text: 'Copied context',
            item_type: 'answer',
            step_sequence: 1,
            item_sequence: 1,
          },
        ],
        media: [],
      },
    };

    const parentFork: ChatRelationSummary = {
      chat_id: 5,
      kind: 'fork',
      note: 'Parent chat',
      background_task: true,
      parent_tool_call_item_id: 30,
      anchor_message_id: 10,
      anchor_tool_call_item_id: 40,
      anchor_step_sequence: 1,
      anchor_item_sequence: 2,
    };

    const wrapper = mount(ChatMessageBubble, {
      props: {
        message,
        index: 0,
        parentForkRelation: parentFork,
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
      ':scope > .message-answer-part, :scope > .message-fork-entry'
    );

    expect(entries).toHaveLength(3);
    expect(entries[0]?.text()).toContain('Copied context');
    expect(entries[1]?.get('.message-fork-card').classes()).toContain('message-fork-card--parent');
    expect(entries[1]?.text()).toContain('Fork of');
    expect(entries[1]?.text()).toContain('Parent chat');
    expect(entries[1]?.find('.chat-relation-indicators__background-task').exists()).toBe(false);
    expect(entries[2]?.text()).toContain('Child answer');
  });

  it('uses spawn labels for positioned spawn relations', () => {
    const message: ChatBranchMessage = {
      id: 10,
      role: 'assistant',
      status: 'done',
      content: { items: [], parts: [], media: [] },
    };

    const spawn: ChatRelationSummary = {
      chat_id: 6,
      kind: 'spawn',
      note: 'Fresh subchat',
      background_task: true,
      last_message_status: 'canceled',
      anchor_message_id: 10,
      anchor_tool_call_item_id: 41,
      anchor_step_sequence: 1,
      anchor_item_sequence: 2,
    };

    const wrapper = mount(ChatMessageBubble, {
      props: {
        message,
        index: 0,
        forkRelations: [spawn],
      },
      global: {
        stubs: {
          RouterLink: {
            template: '<a><slot /></a>',
          },
        },
      },
    });

    const relation = wrapper.get('.message-fork-card');
    expect(relation.text()).toContain('Spawned into');
    expect(relation.text()).toContain('Fresh subchat');
    expect(relation.find('.chat-relation-indicators__background-task').exists()).toBe(true);
    expect(relation.get('.chat-generation-state').classes()).toContain(
      'chat-generation-state--canceled'
    );
  });

  it('distinguishes copying the final answer from copying all answer items', async () => {
    setPreferredLocale('ru');
    const message: ChatBranchMessage = {
      id: 10,
      role: 'assistant',
      status: 'done',
      content: {
        items: [],
        parts: [],
        media: [],
      },
    };

    const wrapper = mount(ChatMessageBubble, {
      props: {
        message,
        index: 0,
        copied: true,
      },
    });

    expect(wrapper.get('.copy-hint').text()).toBe('Скопировано');

    await wrapper.setProps({ copiedAll: true });

    expect(wrapper.get('.copy-hint').text()).toBe('Скопировано всё');
  });

  it('renders request and summary as two independently collapsed system events', async () => {
    const request = mount(ChatMessageBubble, {
      props: { message: handoffMessage(20, 'user', 'handoff_request', 'Internal request'), index: 0 },
    });
    const summary = mount(ChatMessageBubble, {
      props: { message: handoffMessage(21, 'assistant', 'handoff_summary', 'Transfer summary'), index: 1 },
    });

    const requestToggle = request.get('.handoff-system-event__toggle');
    const summaryToggle = summary.get('.handoff-system-event__toggle');

    expect(requestToggle.text()).toContain('Handoff to a new chat requested');
    expect(summaryToggle.text()).toContain('Handoff summary prepared');
    expect(requestToggle.attributes('aria-expanded')).toBe('false');
    expect(summaryToggle.attributes('aria-expanded')).toBe('false');
    expect(request.get('.message-expanded-body').attributes('style')).toContain('display: none');
    expect(summary.get('.message-expanded-body').attributes('style')).toContain('display: none');

    await requestToggle.trigger('click');

    expect(requestToggle.attributes('aria-expanded')).toBe('true');
    expect(request.get('.message-expanded-body').attributes('style')).not.toContain('display: none');
    expect(request.get('.message-content').text()).toContain('Internal request');
    expect(summaryToggle.attributes('aria-expanded')).toBe('false');
  });

  it.each([
    ['generating', 'Preparing handoff summary…'],
    ['error', 'Handoff failed'],
    ['canceled', 'Handoff canceled'],
  ] as const)('shows the %s summary status in the compact row', (status, label) => {
    const message = handoffMessage(22, 'assistant', 'handoff_summary', '', status);
    if (status === 'error') message.error_detail = 'Provider error';

    const wrapper = mount(ChatMessageBubble, {
      props: { message, index: 0 },
    });

    expect(wrapper.get('.handoff-system-event__toggle').text()).toContain(label);
    expect(wrapper.get('.handoff-system-event__toggle').attributes('aria-expanded')).toBe('false');
  });

  it('treats an empty expected assistant message as a pending handoff summary', () => {
    const message: ChatBranchMessage = {
      id: 23,
      role: 'assistant',
      status: 'generating',
      content: { items: [], parts: [], media: [] },
    };

    const wrapper = mount(ChatMessageBubble, {
      props: { message, index: 0, expectedHandoffEventKind: 'handoff_summary' },
    });

    expect(wrapper.get('.handoff-system-event__toggle').text()).toContain('Preparing handoff summary…');
  });

  it('renders handoff context as an ordinary editable user message', () => {
    const wrapper = mount(ChatMessageBubble, {
      props: {
        message: handoffMessage(24, 'user', 'handoff_context', 'Continue from this context'),
        index: 0,
      },
    });

    expect(wrapper.find('.handoff-system-event__toggle').exists()).toBe(false);
    expect(wrapper.get('.message-content').text()).toContain('Continue from this context');
    expect(wrapper.find('[aria-label="Branch from message 1"]').exists()).toBe(true);
  });

  it('renders structured handoff history and message as localized collapsed sections', async () => {
    setPreferredLocale('ru');

    const message: ChatBranchMessage = {
      id: 27,
      role: 'user',
      status: 'done',
      content: {
        items: [
          {
            step_id: 1,
            step_sequence: 1,
            item_id: 10,
            item_sequence: 1,
            item_type: 'handoff_history',
          },
          {
            step_id: 1,
            step_sequence: 1,
            item_id: 11,
            item_sequence: 2,
            item_type: 'handoff_message',
          },
        ],
        parts: [
          {
            content_id: 1,
            sequence: 1,
            text: 'Original request',
            item_type: 'handoff_history',
            step_id: 1,
            step_sequence: 1,
            item_id: 10,
            item_sequence: 1,
            handoff_entry: {
              entry_kind: 'message',
              role: 'assistant',
              created_at: '2026-07-22T10:30:00Z',
              omitted_count: null,
            },
          },
          {
            content_id: 2,
            sequence: 2,
            text: '<continued in new chat>',
            item_type: 'handoff_history',
            step_id: 1,
            step_sequence: 1,
            item_id: 10,
            item_sequence: 1,
            handoff_entry: {
              entry_kind: 'continuation',
              role: null,
              created_at: '2026-07-22T10:31:00Z',
              omitted_count: null,
            },
          },
          {
            content_id: 3,
            sequence: 1,
            text: 'Transfer summary',
            item_type: 'handoff_message',
            step_id: 1,
            step_sequence: 1,
            item_id: 11,
            item_sequence: 2,
          },
        ],
        media: [
          {
            id: 4,
            step_id: 1,
            step_sequence: 1,
            item_id: 10,
            item_sequence: 1,
            item_type: 'handoff_history',
            external_id: 'content-4',
            sequence: 3,
            kind: 'media',
            media: {
              external_id: 'file-4',
              filename: 'full_conversation.md',
              mime_type: 'text/markdown',
              size_bytes: 128,
              sha256: 'sha256',
              is_image: false,
            },
          },
        ],
      },
    };

    const wrapper = mount(ChatMessageBubble, { props: { message, index: 0 } });
    const sections = wrapper.findAll('.handoff-context__section');

    expect(sections).toHaveLength(2);
    expect(sections[0]?.get('summary').text()).toBe('История');
    expect(sections[1]?.get('summary').text()).toBe('Сообщение для передачи');
    expect(sections[0]?.attributes('open')).toBeUndefined();
    expect(sections[1]?.attributes('open')).toBeUndefined();
    expect(sections[0]?.text()).toContain('Ассистент');
    expect(sections[0]?.text()).toContain('Продолжено в новом чате');
    expect(sections[0]?.text()).toContain('full_conversation.md');
    expect(sections[1]?.text()).toContain('Transfer summary');
    expect(wrapper.find('.message-answer-part').exists()).toBe(false);

    await sections[0]?.get('summary').trigger('click');

    expect(sections[0]?.attributes('open')).toBe('');
    expect(sections[1]?.attributes('open')).toBeUndefined();
  });

  it('groups handoff items inline inside mixed messages without changing ordinary items', () => {
    const message: ChatBranchMessage = {
      id: 25,
      role: 'user',
      status: 'done',
      content: {
        items: [
          {
            step_id: 1,
            step_sequence: 1,
            item_id: 10,
            item_sequence: 1,
            item_type: 'input',
          },
          {
            step_id: 1,
            step_sequence: 1,
            item_id: 11,
            item_sequence: 2,
            item_type: 'handoff_request',
          },
        ],
        parts: [
          {
            content_id: 1,
            sequence: 1,
            text: 'Ordinary content',
            item_type: 'input',
            step_id: 1,
            step_sequence: 1,
            item_id: 10,
            item_sequence: 1,
          },
          {
            content_id: 2,
            sequence: 1,
            text: 'Internal request',
            item_type: 'handoff_request',
            step_id: 1,
            step_sequence: 1,
            item_id: 11,
            item_sequence: 2,
          },
        ],
        media: [],
      },
    };

    const wrapper = mount(ChatMessageBubble, { props: { message, index: 0 } });

    expect(wrapper.find('.handoff-system-event__toggle').exists()).toBe(false);
    expect(wrapper.get('.message-answer-part').text()).toContain('Ordinary content');
    expect(wrapper.get('.handoff-inline-event').attributes('open')).toBeUndefined();
    expect(wrapper.get('.handoff-inline-event > summary').text()).toBe('Handoff request');
    expect(wrapper.get('.handoff-inline-event__content').text()).toContain('Internal request');
  });

  it('keeps only read-only actions for messages containing handoff events', async () => {
    const message = handoffMessage(26, 'assistant', 'handoff_summary', 'Transfer summary', 'error');
    message.working = { step_count: 1, completed_step_duration_ms: 0 };
    message.usage = { total: { input_tokens: 10 } };

    const wrapper = mount(ChatMessageBubble, {
      attachTo: document.body,
      props: {
        message,
        index: 0,
        canDelete: true,
      },
    });

    await wrapper.get('.handoff-system-event__toggle').trigger('click');

    expect(wrapper.find('[aria-label="Copy message 1"]').exists()).toBe(true);
    expect(wrapper.find('[aria-label="Branch from message 1"]').exists()).toBe(false);
    expect(wrapper.find('.retry-link').exists()).toBe(false);

    await wrapper.get('[aria-label="More actions for message 1"]').trigger('click');

    const menuText = document.body.querySelector('.message-actions-menu')?.textContent || '';
    expect(menuText).toContain('Stats');
    expect(menuText).toContain('Bookmark');
    expect(menuText).not.toContain('Edit');
    expect(menuText).not.toContain('Branch to new chat');
    expect(menuText).not.toContain('Delete');

    wrapper.unmount();
  });
});
