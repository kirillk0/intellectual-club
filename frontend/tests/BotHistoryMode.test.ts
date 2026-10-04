import { flushPromises, shallowMount, type VueWrapper } from '@vue/test-utils';
import { VueQueryPlugin } from '@tanstack/vue-query';
import { createMemoryHistory, createRouter } from 'vue-router';
import { computed, effectScope, ref } from 'vue';

const mocks = vi.hoisted(() => ({ create: vi.fn(), get: vi.fn(), list: vi.fn(), update: vi.fn() }));
vi.mock('@/api/jsonApi', async () => ({
  ...(await vi.importActual<typeof import('@/api/jsonApi')>('@/api/jsonApi')),
  jsonApiCreate: mocks.create,
  jsonApiGet: mocks.get,
  jsonApiList: mocks.list,
  jsonApiUpdate: mocks.update,
}));

import CrudHeader from '@/components/CrudHeader.vue';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { serverStateQueryClient } from '@/features/serverState/queryClient';
import { useChatContextPanel } from '@/features/chat/model/useChatContextPanel';
import BotEditView from '@/views/catalogs/BotEditView.vue';
import { ruMessages } from '@/i18n/messages';
import type { Bot, ChatBranchMessage, HistoryMode, LlmConfiguration } from '@/types/api';

const botDocument = (mode: HistoryMode) => ({
  data: { id: '27', type: 'bots', attributes: { name: 'History bot', history_mode: mode, can_edit: true } },
});
let wrapper: VueWrapper | null = null;

async function mountView(path: string) {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/catalogs/bots/:id', component: { template: '<div />' } }],
  });
  await router.push(path);
  await router.isReady();
  wrapper = shallowMount(BotEditView, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: serverStateQueryClient }]] },
  });
  await flushPromises();
  await wrapper.findAll('button.tab').find((button) => button.text() === 'Settings')!.trigger('click');
  return wrapper;
}

describe('bot history mode', () => {
  beforeEach(() => {
    serverStateQueryClient.clear();
    useNavigationStack().reset();
    vi.resetAllMocks();
    mocks.list.mockResolvedValue({ data: [] });
  });
  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    serverStateQueryClient.clear();
    useNavigationStack().reset();
  });

  it('defaults to agent, tracks changes and resets the draft', async () => {
    const view = await mountView('/catalogs/bots/new');
    const select = view.get<HTMLSelectElement>('#bot-history-mode');
    expect(select.element.value).toBe('agent');
    expect(Array.from(select.element.options).map((option) => option.value)).toEqual(['agent', 'chat', 'full']);
    for (const option of Array.from(select.element.options)) {
      expect(ruMessages[option.text as keyof typeof ruMessages]).toBeTruthy();
    }
    await select.setValue('full');
    expect(view.getComponent(CrudHeader).props('dirty')).toBe(true);
    view.getComponent(CrudHeader).vm.$emit('cancel');
    await flushPromises();
    expect(select.element.value).toBe('agent');
    expect(view.getComponent(CrudHeader).props('dirty')).toBe(false);
  });

  it('loads full and saves chat through JSON:API', async () => {
    mocks.get.mockResolvedValue(botDocument('full'));
    mocks.update.mockResolvedValue(botDocument('chat'));
    const view = await mountView('/catalogs/bots/27');
    const select = view.get<HTMLSelectElement>('#bot-history-mode');
    expect(select.element.value).toBe('full');
    await select.setValue('chat');
    view.getComponent(CrudHeader).vm.$emit('save');
    await vi.waitFor(() => expect(mocks.update).toHaveBeenCalledTimes(1));
    expect(mocks.update.mock.calls[0]?.[3]).toMatchObject({ history_mode: 'chat' });
  });

  it('uses usage for agent/full/No bot and visible dialogue estimates for chat', () => {
    const bot = ref<Bot | null>(null);
    const scope = effectScope();
    const panel = scope.run(() => useChatContextPanel({
      chatId: computed(() => 1),
      branch: ref([{ token_count: 10 }, { token_count: 20, content: { parts: [{ item_type: 'steering', text: 'Changed' }] }, usage: { latest_step: { input_tokens: 700, output_tokens: 100 } } }] as ChatBranchMessage[]),
      readOnly: computed(() => false),
      promptSources: ref({ bot: [], chat: [], configuration: [], user: [] }),
      promptBlocks: ref([]),
      currentConfig: computed(() => ({ context_length: 1000 }) as LlmConfiguration),
      currentBotInfo: computed(() => bot.value),
      isMobile: ref(false), leftOpen: ref(false),
      messageConfigLabel: () => '', routeFullPath: () => '', routeQuery: () => ({}),
      replaceRouteQuery: async () => {}, stackOpen: () => {},
    }))!;
    try {
      expect(panel.contextUsageTitle.value).toBe('800 / 1000 tokens');
      for (const history_mode of ['agent', 'full', 'chat'] as const) {
        bot.value = { history_mode } as Bot;
        expect(panel.contextUsageTitle.value).toBe(`${history_mode === 'chat' ? 32 : 800} / 1000 tokens`);
      }
    } finally {
      scope.stop();
    }
  });
});
