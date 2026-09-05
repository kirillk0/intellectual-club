import { DOMWrapper, flushPromises, mount, type VueWrapper } from '@vue/test-utils';

import ChatConfigurationSelect from '@/features/chat/components/ChatConfigurationSelect.vue';
import { setPreferredLocale } from '@/i18n';
import type { LlmConfiguration } from '@/types/api';

const defaultConfig: LlmConfiguration = { id: 1, label: 'Default model', enabled: true };
const activeConfig: LlmConfiguration = { id: 2, label: 'Claude active', enabled: true };
const disabledConfig: LlmConfiguration = { id: 3, label: 'Claude archived', enabled: false };
const incompatibleConfig: LlmConfiguration = { id: 4, label: 'Claude other bot', enabled: true };

let wrapper: VueWrapper;
const body = () => new DOMWrapper(document.body);
const menu = () => body().get('.config-select__menu');
const input = () => menu().get<HTMLInputElement>('input');
const labels = () => menu().findAll('[role="menuitem"]').map((item) => item.text());

beforeEach(() => {
  setPreferredLocale('en');
  wrapper = mount(ChatConfigurationSelect, {
    attachTo: document.body,
    props: {
      modelValue: 1,
      disabled: false,
      defaultConfig,
      selectableConfigs: [defaultConfig, activeConfig],
      regularSelectableConfigs: [activeConfig],
      moreConfigs: [disabledConfig, incompatibleConfig],
      selectedDisabledConfig: null,
      configLabel: (config: LlmConfiguration) => config.label,
    },
  });
});

afterEach(() => {
  wrapper.unmount();
  document.body.innerHTML = '';
  setPreferredLocale(null);
});

it('reveals search on the first typed character and includes disabled and incompatible configurations', async () => {
  await wrapper.get('button').trigger('click');
  expect(menu().find('input').exists()).toBe(false);
  expect(labels()).toEqual(['Default model', 'Claude active', 'More‹']);
  expect(document.activeElement).toBe(menu().element);

  await menu().trigger('keydown', { key: 'C' });
  await flushPromises();
  expect(input().element.value).toBe('C');
  expect(document.activeElement).toBe(input().element);
  await input().setValue('  CLAUDE  ');
  expect(labels()).toEqual(['Claude active', 'Claude archived (disabled)', 'Claude other bot (incompatible)']);

  await input().setValue('archived');
  await input().trigger('keydown', { key: 'Enter' });
  expect(wrapper.emitted('update:modelValue')).toEqual([[3]]);
  expect(wrapper.emitted('change')).toHaveLength(1);
  expect(body().find('[role="menu"]').exists()).toBe(false);
  expect(document.activeElement).toBe(wrapper.get('button').element);
});

it('starts typing from the focused closed selector and navigates filtered results with arrows', async () => {
  await wrapper.get('button').trigger('keydown', { key: 'c' });
  await flushPromises();
  expect(input().element.value).toBe('c');
  await input().setValue('claude');
  await input().trigger('keydown', { key: 'ArrowDown' });
  expect(document.activeElement?.textContent?.trim()).toBe('Claude active');
  await new DOMWrapper(document.activeElement!).trigger('keydown', { key: 'ArrowDown' });
  expect(document.activeElement?.textContent?.trim()).toBe('Claude archived (disabled)');
  await new DOMWrapper(document.activeElement!).trigger('click');
  expect(wrapper.emitted('update:modelValue')).toEqual([[3]]);
});

it('shows empty results, restores all options on clearing, and resets after Escape or an outside click', async () => {
  await wrapper.get('button').trigger('click');
  await menu().trigger('keydown', { key: 'z' });
  await flushPromises();
  expect(menu().get('[role="status"]').text()).toBe('No configurations found.');
  await input().trigger('keydown', { key: 'Enter' });
  expect(wrapper.emitted('change')).toBeUndefined();

  await input().setValue('');
  expect(labels()).toHaveLength(5);
  await input().trigger('keydown', { key: 'Escape' });
  expect(body().find('[role="menu"]').exists()).toBe(false);
  expect(document.activeElement).toBe(wrapper.get('button').element);

  await wrapper.get('button').trigger('click');
  expect(menu().find('input').exists()).toBe(false);
  await menu().trigger('keydown', { key: 'z' });
  await body().trigger('click');
  await wrapper.get('button').trigger('click');
  expect(menu().find('input').exists()).toBe(false);
  expect(labels()).toHaveLength(3);
});

it('switches from the More submenu to the same search', async () => {
  await wrapper.get('button').trigger('click');
  await menu().get('.config-select__submenu-trigger').trigger('click');
  const submenu = body().get('.config-select__submenu-menu');
  await submenu.get('button').trigger('keydown', { key: 'a' });
  await flushPromises();
  expect(body().find('.config-select__submenu-menu').exists()).toBe(false);
  expect(input().element.value).toBe('a');
  expect(document.activeElement).toBe(input().element);
});

it('supports opening search by touch and translates the search UI and statuses', async () => {
  setPreferredLocale('ru');
  await wrapper.get('button').trigger('click');
  const toggle = menu().get('.config-select__search-toggle');
  expect(toggle.attributes('aria-label')).toBe('Поиск конфигураций');
  await toggle.trigger('click');
  await flushPromises();
  expect(input().attributes('placeholder')).toBe('Поиск конфигураций');
  expect(document.activeElement).toBe(input().element);
  await input().setValue('claude');
  expect(labels()).toContain('Claude archived (отключено)');
  expect(labels()).toContain('Claude other bot (несовместимо)');
  await input().setValue('missing');
  expect(menu().get('[role="status"]').text()).toBe('Конфигурации не найдены.');
});

it('does not intercept shortcuts, composition, typing elsewhere, or input when disabled', async () => {
  await wrapper.get('button').trigger('click');
  for (const modifiers of [{ ctrlKey: true }, { metaKey: true }, { altKey: true }, { isComposing: true }]) {
    await menu().trigger('keydown', { key: 'c', ...modifiers });
    expect(menu().find('input').exists()).toBe(false);
  }
  const composer = document.createElement('textarea');
  document.body.append(composer);
  await new DOMWrapper(composer).trigger('keydown', { key: 'c' });
  expect(menu().find('input').exists()).toBe(false);
  await menu().trigger('keydown', { key: 'Escape' });
  await wrapper.setProps({ disabled: true });
  await wrapper.get('.config-select').trigger('keydown', { key: 'c' });
  expect(body().find('[role="menu"]').exists()).toBe(false);
});
