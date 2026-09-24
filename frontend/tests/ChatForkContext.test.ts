import { mount } from '@vue/test-utils';
import ChatForkContext from '@/components/chat/ChatForkContext.vue';
import { setPreferredLocale } from '@/i18n';
import type { ForkContext } from '@/types/api';

const context = (): ForkContext => ({
  status: 'available', live: true, read_only: true, revision: 'prefix-1',
  messages: [{
    key: 'inherited-0', role: 'assistant', source_chat_id: 3, source_message_id: 4, source_url: '/chats/3',
    content: [{
      type: 'steering', step_sequence: 1, item_sequence: 1,
      parts: [{ text: '<script>evil()</script> ![remote](https://remote.invalid/pixel.png)' }],
      attachments: [{ name: 'source.png', kind: 'media', mime_type: 'image/png', size_bytes: 1, enabled: true, url: '/api/bff/chat-messages/4/contents/5/file' }],
    }],
  }],
});

afterEach(() => setPreferredLocale(null));

it('renders isolated read-only live context with safe text and source file URLs', () => {
  setPreferredLocale('en');
  const wrapper = mount(ChatForkContext, { props: { context: context() } });
  expect(wrapper.text()).toContain('Inherited live context');
  expect(wrapper.text()).toContain('It may change when the source is edited.');
  expect(wrapper.text()).toContain('<script>evil()</script>');
  expect(wrapper.find('script').exists()).toBe(false);
  expect(wrapper.findAll('img')).toHaveLength(1);
  expect(wrapper.get('img').attributes('src')).toBe('/api/bff/chat-messages/4/contents/5/file');
  expect(wrapper.find('a[href="/chats/3"]').exists()).toBe(true);
  expect(wrapper.find('button').exists()).toBe(false);
  expect(wrapper.find('[data-message-id]').exists()).toBe(false);
  expect(wrapper.find('.generating, .spinner').exists()).toBe(false);
  wrapper.unmount();
});

it('does not render arbitrary source or attachment URLs, including SVG embeds', () => {
  const prefix = context();
  prefix.messages[0]!.source_url = 'javascript:alert(1)';
  prefix.messages[0]!.content[0]!.attachments[0]!.url = '//remote.invalid/pixel';
  const wrapper = mount(ChatForkContext, { props: { context: prefix } });
  expect(wrapper.find('a').exists()).toBe(false);
  expect(wrapper.find('img').exists()).toBe(false);
  expect(wrapper.text()).toContain('Attachment unavailable');
  wrapper.unmount();
});

it('localizes the unavailable prefix without exposing any messages', () => {
  setPreferredLocale('ru');
  const prefix = context();
  prefix.status = 'unavailable';
  const wrapper = mount(ChatForkContext, { props: { context: prefix } });
  expect(wrapper.text()).toContain('Наследуемый живой контекст');
  expect(wrapper.text()).toContain('Наследуемый контекст недоступен');
  expect(wrapper.find('article').exists()).toBe(false);
  expect(wrapper.find('a').exists()).toBe(false);
  wrapper.unmount();
});
