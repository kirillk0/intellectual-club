import { mount } from '@vue/test-utils';

import ChatQueuedMessagesPanel from '@/components/chat/ChatQueuedMessagesPanel.vue';
import type { ChatQueuedMessage } from '@/features/chat/model/chatViewModel.shared';
import { setPreferredLocale } from '@/i18n';

const messages: ChatQueuedMessage[] = [
  {
    id: 1,
    chat_id: 5,
    kind: 'steer',
    status: 'pending',
    target_generation_message_id: 20,
    contents: [{ id: 11, sequence: 1, kind: 'text', content_text: 'Use a shorter answer' }],
  },
  {
    id: 2,
    chat_id: 5,
    kind: 'follow_up',
    status: 'blocked',
    anchor_message_id: 20,
    blocked_reason: 'generation_error',
    contents: [
      { id: 21, sequence: 1, kind: 'text', content_text: 'Then summarize it' },
      {
        id: 22,
        sequence: 2,
        kind: 'media',
        file: { id: 100, filename: 'brief.pdf', mime_type: 'application/pdf', size_bytes: 4096 },
      },
    ],
  },
];

describe('ChatQueuedMessagesPanel', () => {
  afterEach(() => {
    setPreferredLocale(null);
  });

  it('shows steer and FIFO follow-up state before model delivery', async () => {
    const wrapper = mount(ChatQueuedMessagesPanel, {
      props: {
        messages,
        activeGenerationId: null,
        actionId: null,
        headFollowUpId: 2,
      },
      global: { stubs: { SvgIcon: true } },
    });

    expect(wrapper.text()).toContain('Not sent to the model yet');
    expect(wrapper.text()).toContain('Steer');
    expect(wrapper.text()).toContain('Queued');
    expect(wrapper.text()).toContain('#1');
    expect(wrapper.text()).toContain('Paused');
    expect(wrapper.text()).toContain('brief.pdf');
    expect(wrapper.text()).toContain('Send next');

    const sendNext = wrapper.findAll('button').find((button) => button.text() === 'Send next');
    await sendNext?.trigger('click');
    expect(wrapper.emitted('send-next')).toEqual([[messages[1]]]);
  });

  it('hides Send next while a generation is active', () => {
    const wrapper = mount(ChatQueuedMessagesPanel, {
      props: {
        messages,
        activeGenerationId: 20,
        actionId: null,
        headFollowUpId: 2,
      },
      global: { stubs: { SvgIcon: true } },
    });

    expect(wrapper.findAll('button').some((button) => button.text() === 'Send next')).toBe(false);
  });

  it('localizes queue state and actions in Russian', () => {
    setPreferredLocale('ru');
    const wrapper = mount(ChatQueuedMessagesPanel, {
      props: {
        messages,
        activeGenerationId: null,
        actionId: null,
        headFollowUpId: 2,
      },
      global: { stubs: { SvgIcon: true } },
    });

    expect(wrapper.text()).toContain('Ещё не отправлено модели');
    expect(wrapper.text()).toContain('Приостановлено');
    expect(wrapper.text()).toContain('Убрать из очереди');
    expect(wrapper.text()).toContain('Отправить следующее');
  });
});
