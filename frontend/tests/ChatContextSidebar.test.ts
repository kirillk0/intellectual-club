import { mount } from '@vue/test-utils';

import ChatContextSidebar from '@/features/chat/components/ChatContextSidebar.vue';
import type { ActiveToolBinding } from '@/features/chat/types';
import { setPreferredLocale } from '@/i18n';

const binding = (
  id: number,
  name: string,
  backgroundFunctionsUnavailable?: boolean
): ActiveToolBinding => ({
  id,
  source: 'chat',
  alias: `tool_${id}`,
  sequence: id,
  tool_instance_id: id,
  enabled: true,
  ...(backgroundFunctionsUnavailable === undefined
    ? {}
    : { background_functions_unavailable: backgroundFunctionsUnavailable }),
  tool_instance: {
    id,
    name,
    alias: `tool_${id}`,
    type: 'ssh',
  },
});

const mountSidebar = (activeToolBindings: ActiveToolBinding[]) =>
  mount(ChatContextSidebar, {
    props: {
      isMobile: false,
      leftTab: 'prompt',
      isAgentHistoryMode: false,
      agentContextTokenCount: null,
      promptTokenCount: 0,
      historyTokenCount: 0,
      totalTokenCount: 0,
      showContextUsageIndicator: false,
      contextUsagePercentRounded: 0,
      contextUsageTitle: '',
      isContextSoftLimitReached: false,
      contextUsagePercent: 0,
      branchSearchTerm: '',
      hasBranchSearch: false,
      branchSearchLoading: false,
      branchSearchError: '',
      branchSearchResults: { active: [], inactive: [] },
      branch: [],
      linkedBlocks: [],
      sourceLabels: {},
      botToolsLoading: false,
      botToolsError: '',
      activeToolBindings,
      formatStepMetric: String,
      searchHitMeta: () => '',
      messageMetaLabel: () => '',
      messageText: () => '',
      preview: (text: string) => text,
      hasBlockVersion: () => false,
      formatBlockVersion: () => '',
    },
  });

describe('ChatContextSidebar tool warnings', () => {
  afterEach(() => setPreferredLocale(null));

  it('marks only bindings with unavailable background functions and keeps the row openable', async () => {
    setPreferredLocale('ru');
    const wrapper = mountSidebar([
      binding(11, 'Unavailable background tool', true),
      binding(12, 'Available background tool', false),
      binding(13, 'Legacy tool'),
    ]);

    const rows = wrapper.findAll('.tool-binding-list-item');
    expect(rows).toHaveLength(3);
    expect(rows[0].find('.background-functions-warning').exists()).toBe(true);
    expect(rows[1].find('.background-functions-warning').exists()).toBe(false);
    expect(rows[2].find('.background-functions-warning').exists()).toBe(false);

    const warning = rows[0].get('.background-functions-warning');
    const label =
      'Фоновые функции недоступны, потому что функция check_background_task_status отключена.';
    expect(warning.text()).toBe('!');
    expect(warning.attributes('title')).toBe(label);
    expect(warning.attributes('aria-label')).toBe(label);

    await rows[0].get('.tool-binding-list-item__body').trigger('click');
    expect(wrapper.emitted('open-context-tool-editor')).toEqual([[11]]);
  });
});
