import { mount } from '@vue/test-utils';
import ChatForkContext from '@/components/chat/ChatForkContext.vue';
import { setPreferredLocale } from '@/i18n';
import type { ForkContext } from '@/types/api';

const context = (): ForkContext => ({
  status: 'available', live: true, read_only: true, revision: 'prefix-1',
  task: 'Check the **fork** <script>evil()</script>',
  message_count: 12,
  step_count: 30,
});

afterEach(() => setPreferredLocale(null));

it('summarizes inherited history and shows the fork task as the first message', () => {
  setPreferredLocale('en');
  const wrapper = mount(ChatForkContext, { props: { context: context() } });
  expect(wrapper.text()).toContain('Inherited context · Messages: 12 · Steps: 30 · history is read-only');
  const task = wrapper.get('.fork-context__task');
  expect(task.classes()).toContain('user');
  expect(task.text()).toContain('Fork task');
  expect(task.get('strong').text()).toBe('fork');
  expect(wrapper.find('script').exists()).toBe(false);
  expect(wrapper.find('article').exists()).toBe(false);
  expect(wrapper.find('button').exists()).toBe(false);
  expect(wrapper.find('[data-message-id]').exists()).toBe(false);
  wrapper.unmount();
});

it('omits the task bubble when the fork has no task text', () => {
  const prefix = context();
  prefix.task = '   ';
  const wrapper = mount(ChatForkContext, { props: { context: prefix } });
  expect(wrapper.find('.fork-context__task').exists()).toBe(false);
  wrapper.unmount();
});

it('localizes the unavailable prefix and still shows the task', () => {
  setPreferredLocale('ru');
  const prefix = context();
  prefix.status = 'unavailable';
  prefix.message_count = null;
  prefix.step_count = null;
  const wrapper = mount(ChatForkContext, { props: { context: prefix } });
  expect(wrapper.text()).toContain('Наследуемый контекст недоступен');
  expect(wrapper.text()).not.toContain('Сообщений');
  expect(wrapper.text()).toContain('Задача форка');
  expect(wrapper.find('a').exists()).toBe(false);
  wrapper.unmount();
});

it('localizes the summary', () => {
  setPreferredLocale('ru');
  const wrapper = mount(ChatForkContext, { props: { context: context() } });
  expect(wrapper.text()).toContain('Унаследованный контекст · Сообщений: 12 · Шагов: 30 · история только для чтения');
  wrapper.unmount();
});
