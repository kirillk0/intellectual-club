import { mount } from '@vue/test-utils';
import ChatGenerationStateIndicator from '@/components/chat/ChatGenerationStateIndicator.vue';
import { setPreferredLocale } from '@/i18n';

describe('ChatGenerationStateIndicator', () => {
  beforeEach(() => {
    setPreferredLocale('en');
  });

  afterEach(() => {
    setPreferredLocale(null);
  });

  it('renders the shared animated typing indicator while generating', () => {
    const wrapper = mount(ChatGenerationStateIndicator, {
      props: { state: 'generating' },
    });

    expect(wrapper.get('.chat-generation-state').attributes('aria-label')).toBe('Generating');
    expect(wrapper.get('.typing-indicator').findAll(':scope > span')).toHaveLength(3);
  });

  it('renders an accessible error icon when generation fails', () => {
    const wrapper = mount(ChatGenerationStateIndicator, {
      props: { state: 'error' },
    });

    const indicator = wrapper.get('.chat-generation-state');
    expect(indicator.attributes('aria-label')).toBe('Generation failed');
    expect(indicator.attributes('role')).toBe('status');
    expect(indicator.attributes('aria-live')).toBe('polite');
    expect(indicator.classes()).toContain('chat-generation-state--error');
    expect(wrapper.find('.chat-generation-state__error-icon .svg-icon').exists()).toBe(true);
  });

  it('renders nothing without a state', () => {
    const wrapper = mount(ChatGenerationStateIndicator, {
      props: { state: null },
    });

    expect(wrapper.find('.chat-generation-state').exists()).toBe(false);
  });
});
