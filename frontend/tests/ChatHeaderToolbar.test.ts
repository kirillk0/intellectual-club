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
