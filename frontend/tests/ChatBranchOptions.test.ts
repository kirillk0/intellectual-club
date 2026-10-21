import { flushPromises, mount } from '@vue/test-utils';

import ChatBranchOptions from '@/features/chat/components/ChatBranchOptions.vue';
import { setPreferredLocale } from '@/i18n';
import type { LlmConfiguration } from '@/types/api';

const current: LlmConfiguration = { id: 1, label: 'Current model', enabled: true };
const other: LlmConfiguration = { id: 2, label: 'Other model', enabled: true };

const mountOptions = (props: Record<string, unknown> = {}) =>
  mount(ChatBranchOptions, {
    attachTo: document.body,
    props: {
      configId: 1,
      startGeneration: true,
      newChat: false,
      currentConfigId: 1,
      selectableConfigs: [current, other],
      defaultConfig: null,
      regularSelectableConfigs: [current, other],
      moreConfigs: [],
      configLabel: (config: LlmConfiguration) => config.label || '',
      ...props,
    },
  });

describe('ChatBranchOptions', () => {
  beforeEach(() => setPreferredLocale('en'));

  afterEach(() => {
    document.body.innerHTML = '';
    setPreferredLocale(null);
  });

  it('selects a configuration from a menu that stacks above the edit dialog without the editor shortcut', async () => {
    const wrapper = mountOptions();

    await wrapper.get('.config-select__trigger').trigger('click');
    const menu = document.body.querySelector<HTMLElement>('.config-select__menu');
    expect(Number(menu?.style.zIndex)).toBeGreaterThan(3000);
    expect(menu?.hasAttribute('data-modal-shortcut-ignore')).toBe(true);
    const items = Array.from(menu?.querySelectorAll<HTMLButtonElement>('[role="menuitem"]') ?? []);
    const labels = items.map((item) => item.textContent?.trim());
    expect(labels.slice(0, 2)).toEqual(['Current model', 'Other model']);
    expect(labels).not.toContain('Edit configuration');

    items[1]?.click();
    await flushPromises();
    expect(wrapper.emitted('update:configId')).toEqual([[2]]);
    wrapper.unmount();
  });

  it('explains that an in-chat branch switches the chat configuration', async () => {
    const wrapper = mountOptions({ configId: 2 });
    expect(wrapper.text()).toContain('This chat will switch to the selected configuration.');

    await wrapper.setProps({ newChat: true });
    expect(wrapper.text()).not.toContain('This chat will switch');
    wrapper.unmount();
  });

  it('toggles the generation start and explains how to continue later', async () => {
    const wrapper = mountOptions({ newChat: true });
    expect(wrapper.text()).not.toContain('Press Continue');

    await wrapper.get('input[type="checkbox"]').setValue(false);
    expect(wrapper.emitted('update:startGeneration')).toEqual([[false]]);

    await wrapper.setProps({ startGeneration: false });
    expect(wrapper.text()).toContain('The new chat opens without a response');

    await wrapper.setProps({ newChat: false });
    expect(wrapper.text()).toContain('The branch is created without a response.');
    wrapper.unmount();
  });
});
