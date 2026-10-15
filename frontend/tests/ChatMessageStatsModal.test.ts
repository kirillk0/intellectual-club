import { mount } from '@vue/test-utils';

import ChatMessageStatsModal from '@/components/chat/ChatMessageStatsModal.vue';
import { setPreferredLocale } from '@/i18n';

const ModalStub = {
  props: ['modalClass'],
  emits: ['cancel'],
  template: '<div class="modal-stub"><slot /></div>',
};

const mountModal = (props: Record<string, unknown>) =>
  mount(ChatMessageStatsModal, {
    props: { open: true, stats: null, ...props },
    global: { stubs: { ModalWindow: ModalStub } },
  });

describe('ChatMessageStatsModal subchat columns', () => {
  beforeEach(() => {
    setPreferredLocale('en');
  });

  afterEach(() => {
    setPreferredLocale(null);
  });

  it('shows message-only stats in a single column when there are no subchats', () => {
    const wrapper = mountModal({ stats: { input_tokens: 10, cost: 0.01 } });

    expect(wrapper.find('.chat-stats-header').exists()).toBe(false);
    expect(wrapper.find('.message-stats-note').exists()).toBe(false);
  });

  it('shows stats without and with subchats side by side', () => {
    const wrapper = mountModal({
      stats: { input_tokens: 10, output_tokens: 4, time_to_first_token_ms: 250, cost: 0.01 },
      subchatStats: { input_tokens: 90, output_tokens: 6, cost: 0.04 },
    });

    expect(wrapper.get('.chat-stats-header').text()).toContain('Without subchats');
    expect(wrapper.get('.chat-stats-header').text()).toContain('With subchats');

    const values = (label: string) =>
      wrapper
        .findAll('.chat-stats-row')
        .find((row) => row.get('.chat-stats-label').text() === label)!
        .findAll('.chat-stats-value')
        .map((cell) => cell.text());
    expect(values('Input tokens (total)')).toEqual(['10', '100']);
    expect(values('Output tokens (total, incl. reasoning)')).toEqual(['4', '10']);
    expect(values('Time to first token')).toEqual(['250 ms', '—']);
    expect(values('Cost (USD)')).toEqual(['0.010000', '0.050000']);
    expect(wrapper.get('.message-stats-note').text()).toBe('Subchats are counted in tokens and cost only.');
  });

  it('shows subchat usage even when the message reported none itself', () => {
    const wrapper = mountModal({ subchatStats: { input_tokens: 90, cost: 0.04 } });

    expect(wrapper.find('.message-stats-empty').exists()).toBe(false);
    expect(wrapper.get('.chat-stats-header').text()).toContain('With subchats');
  });
});
