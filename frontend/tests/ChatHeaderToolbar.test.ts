import { DOMWrapper, mount, type VueWrapper } from '@vue/test-utils';

import ChatHeaderToolbar from '@/features/chat/components/ChatHeaderToolbar.vue';
import { setPreferredLocale } from '@/i18n';
import type { LlmConfiguration } from '@/types/api';

const config: LlmConfiguration = { id: 7, label: 'Main model', enabled: true };

let wrapper: VueWrapper;
const body = () => new DOMWrapper(document.body);
const menu = () => body().get('.floating-dropdown');

const mountToolbar = (props: Record<string, unknown> = {}) =>
  mount(ChatHeaderToolbar, {
    attachTo: document.body,
    props: {
      selectedConfig: 7,
      appliedConfig: 7,
      selectableConfigs: [config],
      defaultConfig: null,
      regularSelectableConfigs: [config],
      moreConfigs: [],
      selectedDisabledConfig: null,
      selectedDisabledConfigReason: null,
      configLabel: (cfg: LlmConfiguration) => cfg.label,
      configSyncStatus: 'synced',
      configSyncError: '',
      configurationOptionsReady: true,
      isGenerating: false,
      menuOpen: true,
      menuStyle: {},
      currentBotId: 3,
      currentBotName: 'Helper',
      currentChatId: 1,
      chatBaseTitle: 'Helper',
      chatFullTitle: 'Helper',
      chatNote: '',
      continuationNav: [],
      creatingChat: false,
      deleting: false,
      canEdit: true,
      handoffPending: false,
      handoffDisabled: false,
      showMissingToolsBanner: false,
      missingRequiredPerUserToolAliases: [],
      setMenuRef: () => {},
      setMenuAnchorRef: () => {},
      setMenuButtonRef: () => {},
      ...props,
    },
  });

beforeEach(() => {
  setPreferredLocale('en');
});

afterEach(() => {
  wrapper.unmount();
  document.body.innerHTML = '';
  setPreferredLocale(null);
});

it('opens the configuration editor from the configuration selector instead of the chat menu', async () => {
  wrapper = mountToolbar();
  expect(menu().text()).not.toContain('Edit configuration');

  await wrapper.get('.config-select__trigger').trigger('click');
  await body().get('.config-select__item--action').trigger('click');
  expect(wrapper.emitted('open-config-editor')).toHaveLength(1);
});

it('offers explicit edit and switch actions for the bot', async () => {
  wrapper = mountToolbar();
  await menu().get('[aria-label="Edit bot"]').trigger('click');
  await menu().get('[aria-label="Switch bot"]').trigger('click');
  expect(wrapper.emitted('open-bot-editor')).toHaveLength(1);
  expect(wrapper.emitted('open-bot-modal')).toHaveLength(1);
});

it('shows only the actions available for the chat and bot', () => {
  wrapper = mountToolbar({ canEdit: false, currentBotId: null, currentBotName: '' });
  expect(menu().find('[aria-label="Edit bot"]').exists()).toBe(false);
  expect(menu().find('[aria-label="Switch bot"]').exists()).toBe(false);
  expect(menu().find('[aria-label="Edit note"]').exists()).toBe(false);
  expect(menu().find('.menu-divider').exists()).toBe(false);
  expect(menu().text()).toContain('No bot');
});

it('keeps the configuration selector available while a response is generating', async () => {
  wrapper = mountToolbar({ isGenerating: true });
  const trigger = wrapper.get('.config-select__trigger');

  expect(trigger.attributes('disabled')).toBeUndefined();
  expect(trigger.attributes('title')).toBe('Main model');
  await trigger.trigger('click');
  expect(body().findAll('.config-select__item').some((item) => item.text() === 'Main model')).toBe(true);
});

it('marks a running generation that uses a configuration other than the selected one', () => {
  wrapper = mountToolbar({ isGenerating: true, generationConfigLabel: 'Previous model' });
  const marker = wrapper.get('.config-generation-mismatch');
  const explanation =
    'Current response is being generated with Previous model. The selected configuration applies to the next message.';

  expect(marker.text()).toBe('Previous model');
  expect(marker.attributes('title')).toBe(explanation);
  expect(marker.attributes('aria-label')).toBe(explanation);
});

it('hides the generation configuration marker when it matches the selection', () => {
  wrapper = mountToolbar({ isGenerating: true });
  expect(wrapper.find('.config-generation-mismatch').exists()).toBe(false);
});
