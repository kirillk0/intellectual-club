import { mount } from '@vue/test-utils';

import ChatRelationIndicators from '@/components/chat/ChatRelationIndicators.vue';
import { setPreferredLocale } from '@/i18n';

describe('ChatRelationIndicators', () => {
  afterEach(() => {
    setPreferredLocale(null);
  });

  it('shows an accessible background marker alongside the canceled state', () => {
    setPreferredLocale('ru');

    const wrapper = mount(ChatRelationIndicators, {
      props: {
        relation: {
          chat_id: 20,
          background_task: true,
          last_message_status: 'canceled',
        },
      },
    });

    const backgroundTask = wrapper.get('.chat-relation-indicators__background-task');
    expect(backgroundTask.attributes('aria-label')).toBe('Запущен как фоновая задача');
    expect(backgroundTask.attributes('title')).toBe('Запущен как фоновая задача');
    expect(backgroundTask.find('.svg-icon').exists()).toBe(true);
    expect(wrapper.get('.chat-generation-state').classes()).toContain(
      'chat-generation-state--canceled'
    );
  });

  it('does not render without a background marker or generation state', () => {
    const wrapper = mount(ChatRelationIndicators, {
      props: {
        relation: {
          chat_id: 20,
          background_task: false,
          last_message_status: 'done',
        },
      },
    });

    expect(wrapper.find('.chat-relation-indicators').exists()).toBe(false);
  });
});
