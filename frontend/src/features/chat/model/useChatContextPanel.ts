import { computed, nextTick, ref, watch, type ComputedRef, type Ref } from 'vue';

import { api } from '@/api/client';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import type {
  ActiveToolInstance,
  ActiveToolBinding,
  BlockSource,
  BranchSearchResults,
  ChatMessageSearchHit,
  LinkedBlock,
} from '@/features/chat/types';
import { displayTimestampIso, formatRelativeDateTime } from '@/utils/dates';
import type { ActiveToolBinding as ApiActiveToolBinding, Bot, ChatBranchMessage, LlmConfiguration } from '@/types/api';
import type { PromptBinding, PromptBlock } from '@/features/chat/model/chatViewModel.shared';

type Params = {
  chatId: ComputedRef<number>;
  branch: Ref<ChatBranchMessage[]>;
  readOnly: ComputedRef<boolean>;
  promptSources: Ref<{
    bot: PromptBinding[];
    chat: PromptBinding[];
    configuration: PromptBinding[];
    user: PromptBinding[];
  }>;
  promptBlocks: Ref<PromptBlock[]>;
  currentConfig: ComputedRef<LlmConfiguration | null>;
  currentBotInfo: ComputedRef<Bot | null>;
  isMobile: Ref<boolean>;
  leftOpen: Ref<boolean>;
  messageConfigLabel: (configId?: number | null) => string;
  routeFullPath: () => string;
  routeQuery: () => Record<string, unknown>;
  replaceRouteQuery: (query: Record<string, any>) => Promise<void>;
  stackOpen: (payload: { path: string; query?: Record<string, string> }) => void;
};

const getQueryString = (value: unknown) =>
  Array.isArray(value) ? value[0] : typeof value === 'string' ? value : undefined;

const normalizeBlockSource = (source: unknown): BlockSource | null => {
  if (source === 'bot' || source === 'chat' || source === 'config' || source === 'user') {
    return source;
  }
  return null;
};

export function useChatContextPanel(params: Params) {
  const linkedBlocks = computed<LinkedBlock[]>(() => {
    const promptBlockItems = [...(params.promptBlocks.value || [])]
      .filter((item) => Boolean(item?.knowledge_block))
      .sort((a, b) => (a.prompt_order ?? 0) - (b.prompt_order ?? 0));

    if (promptBlockItems.length) {
      return promptBlockItems.flatMap((item) => {
        const source = normalizeBlockSource(item.source);
        if (!source || !item.knowledge_block) return [];

        return [
          {
            block: item.knowledge_block,
            source,
            order: item.prompt_order ?? 0,
          },
        ];
      });
    }

    const configurationBlocks = params.promptSources.value.configuration || [];
    const configurationTop = configurationBlocks.filter((binding) => binding.selection === 'top');
    const configurationBottom = configurationBlocks.filter((binding) => binding.selection !== 'top');

    const buckets: Array<{ source: BlockSource; list: PromptBinding[] }> = [
      { source: 'config', list: configurationTop },
      { source: 'bot', list: params.promptSources.value.bot || [] },
      { source: 'chat', list: params.promptSources.value.chat || [] },
      { source: 'config', list: configurationBottom },
      { source: 'user', list: params.promptSources.value.user || [] },
    ];

    const items: LinkedBlock[] = [];
    for (const bucket of buckets) {
      for (const binding of bucket.list || []) {
        if (!binding?.enabled) continue;
        if (!binding.knowledge_block) continue;
        items.push({
          block: binding.knowledge_block,
          source: bucket.source,
          order: items.length,
        });
      }
    }

    return items;
  });

  const formatStepMetric = (value: unknown) => {
    if (value == null || value === '') return '—';
    return String(value);
  };

  const promptTokenCount = computed(() =>
    linkedBlocks.value.reduce((sum, item) => sum + (item.block.token_count || 0), 0)
  );
  const historyTokenCount = computed(() =>
    params.branch.value.reduce((sum, msg) => sum + (msg.token_count || 0), 0)
  );
  const totalTokenCount = computed(() => promptTokenCount.value + historyTokenCount.value);

  const findLatestStepWithUsage = (messages: ChatBranchMessage[]) => {
    for (let i = messages.length - 1; i >= 0; i -= 1) {
      const step = messages[i].usage?.latest_step;
      if (step && (step.input_tokens != null || step.output_tokens != null)) return step;
    }
    return null;
  };

  const isAgentHistoryMode = computed(() => true);
  const agentContextTokenCount = computed<number | null>(() => {
    const step = findLatestStepWithUsage(params.branch.value);
    if (!step) return null;
    const input = typeof step.input_tokens === 'number' ? step.input_tokens : 0;
    const output = typeof step.output_tokens === 'number' ? step.output_tokens : 0;
    return input + output;
  });

  const contextLengthTokens = computed<number | null>(() => {
    const len = params.currentConfig.value?.context_length;
    if (typeof len !== 'number') return null;
    if (!Number.isFinite(len)) return null;
    if (len <= 0) return null;
    return len;
  });

  const contextUsedTokens = computed(() => {
    const used = agentContextTokenCount.value;
    if (typeof used !== 'number' || !Number.isFinite(used)) return 0;
    return Math.max(0, used);
  });

  const contextUsagePercent = computed(() => {
    const len = contextLengthTokens.value;
    if (!len) return 0;
    const ratio = contextUsedTokens.value / len;
    if (!Number.isFinite(ratio)) return 0;
    return Math.max(0, Math.min(100, ratio * 100));
  });
  const contextUsagePercentRounded = computed(() => Math.round(contextUsagePercent.value));
  const showContextUsageIndicator = computed(() => Boolean(contextLengthTokens.value));
  const isContextSoftLimitReached = computed(() => {
    const len = contextLengthTokens.value;
    if (!len) return false;
    const soft = params.currentBotInfo.value?.context_soft_limit_percent;
    if (typeof soft !== 'number' || !Number.isFinite(soft) || soft <= 0) return false;
    return (contextUsedTokens.value / len) * 100 >= soft;
  });
  const contextUsageTitle = computed(() => {
    const len = contextLengthTokens.value;
    if (!len) return '';
    return `${contextUsedTokens.value} / ${len} tokens`;
  });

  const branchSearchTerm = ref('');
  const hasBranchSearch = computed(() => branchSearchTerm.value.trim().length > 0);
  const branchSearchLoading = ref(false);
  const branchSearchError = ref('');
  const branchSearchResults = ref<BranchSearchResults>({ active: [], inactive: [] });

  let branchSearchTimer: number | null = null;
  let branchSearchSeq = 0;

  const resetBranchSearch = () => {
    branchSearchSeq += 1;
    branchSearchResults.value = { active: [], inactive: [] };
    branchSearchLoading.value = false;
    branchSearchError.value = '';
  };

  const runBranchSearch = async (term: string) => {
    if (!params.chatId.value) return;
    const query = term.trim();
    if (!query) {
      resetBranchSearch();
      return;
    }

    const seq = ++branchSearchSeq;
    branchSearchLoading.value = true;
    branchSearchError.value = '';

    try {
      const searchParams = new URLSearchParams();
      searchParams.set('q', query);
      const payload = await api.get<BranchSearchResults>(
        `/api/bff/chats/${params.chatId.value}/search?${searchParams.toString()}`
      );
      if (branchSearchSeq !== seq) return;
      branchSearchResults.value = payload || { active: [], inactive: [] };
    } catch (error) {
      if (branchSearchSeq !== seq) return;
      console.error(error);
      branchSearchError.value = error instanceof Error ? error.message : 'Failed to search messages.';
      branchSearchResults.value = { active: [], inactive: [] };
    } finally {
      if (branchSearchSeq === seq) {
        branchSearchLoading.value = false;
      }
    }
  };

  const scheduleBranchSearch = (value: string) => {
    const query = value.trim();
    if (!query) {
      if (branchSearchTimer != null) window.clearTimeout(branchSearchTimer);
      branchSearchTimer = null;
      resetBranchSearch();
      return;
    }

    if (branchSearchTimer != null) window.clearTimeout(branchSearchTimer);
    branchSearchTimer = window.setTimeout(() => {
      void runBranchSearch(query);
    }, 250);
  };

  const clearBranchSearchTimer = () => {
    if (branchSearchTimer != null) {
      window.clearTimeout(branchSearchTimer);
      branchSearchTimer = null;
    }
  };

  watch(
    () => branchSearchTerm.value,
    (value) => {
      scheduleBranchSearch(value);
    }
  );

  const rerunBranchSearch = () => {
    if (!hasBranchSearch.value) return;
    void runBranchSearch(branchSearchTerm.value.trim());
  };

  const searchHitMeta = (hit: ChatMessageSearchHit) => {
    const time = formatRelativeDateTime(displayTimestampIso(hit));
    const cfgLabel = hit.role === 'assistant' ? params.messageConfigLabel(hit.llm_configuration_id ?? null) : '';
    if (time && cfgLabel) return `${time} (${cfgLabel})`;
    if (time) return time;
    if (cfgLabel) return cfgLabel;
    return hit.role === 'user' ? 'User' : 'Assistant';
  };

  const preview = (text: string) => {
    const normalized = String(text || '').replace(/\s+/g, ' ').trim();
    if (!normalized) return '';
    const limit = params.isMobile.value ? 100 : 160;
    return normalized.length <= limit ? normalized : `${normalized.slice(0, limit)}…`;
  };

  const formatBlockVersion = (value: unknown) => {
    if (value == null) return '';
    if (typeof value === 'number') {
      return Number.isFinite(value) && value > 0 ? `v${value}` : '';
    }
    const text = String(value).trim();
    if (!text) return '';
    if (/^v\d+/i.test(text)) return text;
    if (/^\d+$/.test(text)) return `v${text}`;
    return text;
  };

  const hasBlockVersion = (value: unknown) => formatBlockVersion(value) !== '';

  const botToolsLoading = ref(false);
  const botToolsError = ref('');
  const activeToolInstances = ref<ActiveToolInstance[]>([]);
  const activeToolBindings = ref<ActiveToolBinding[]>([]);

  const hydrate = (payload: { activeToolInstances: ActiveToolInstance[]; activeToolBindings: ApiActiveToolBinding[] }) => {
    activeToolInstances.value = payload.activeToolInstances || [];
    activeToolBindings.value = (payload.activeToolBindings || []).map((binding) => ({
      ...binding,
      enabled: true,
    }));
    botToolsLoading.value = false;
    botToolsError.value = '';
  };

  const messageMetaLabel = (msg: ChatBranchMessage) => {
    const time = formatRelativeDateTime(displayTimestampIso(msg));
    const cfgLabel = msg.role === 'assistant' ? params.messageConfigLabel(msg.llm_configuration_id) : '';
    if (time && cfgLabel) return `${time} (${cfgLabel})`;
    if (time) return time;
    if (cfgLabel) return cfgLabel;
    return msg.role === 'user' ? 'User' : 'Assistant';
  };

  const messageRefs = new Map<number, HTMLElement>();
  const setMessageRef = (id: number | null | undefined, el: HTMLElement | null) => {
    if (!id) return;
    if (!el) {
      messageRefs.delete(id);
      return;
    }
    messageRefs.set(id, el);
  };

  const waitForAnimationFrame = () =>
    new Promise<void>((resolve) => {
      window.requestAnimationFrame(() => resolve());
    });

  const scrollToLastMessage = async (
    opts: { behavior?: ScrollBehavior; block?: ScrollLogicalPosition } = {}
  ) => {
    const last = params.branch.value[params.branch.value.length - 1];
    if (!last?.id) return;

    await nextTick();
    await waitForAnimationFrame();

    const el = messageRefs.get(last.id);
    if (!el) return;

    el.scrollIntoView({
      behavior: opts.behavior ?? 'auto',
      block: opts.block ?? 'start',
    });
  };

  const chatWindowRef = ref<HTMLElement | null>(null);

  const handleBranchItemClick = (id?: number | null) => {
    if (!id) return;
    const el = messageRefs.get(id);
    if (!el) return;
    el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    if (params.isMobile.value) {
      params.leftOpen.value = false;
    }
  };

  const handleSearchResultClick = async (hit: ChatMessageSearchHit, inactive: boolean) => {
    if (!hit?.id) return;

    if (!inactive) {
      handleBranchItemClick(hit.id);
      return;
    }

    if (params.readOnly.value) return;
    if (!params.chatId.value) return;

    try {
      const payload = await api.post<{ branch: ChatBranchMessage[] }>(
        `/api/bff/chats/${params.chatId.value}/activate-branch`,
        {
          message_id: hit.id,
        }
      );

      params.branch.value = payload.branch || [];

      await nextTick();
      handleBranchItemClick(hit.id);
      rerunBranchSearch();
    } catch (error) {
      console.error(error);
      window.alert('Failed to activate the branch.');
    }
  };

  const readFocusMessageQuery = () => {
    const query = params.routeQuery();
    const rawId = getQueryString(query.focusMessage);
    const rawInactive = getQueryString(query.focusInactive);
    const id = rawId ? Number(rawId) : null;
    const inactive = rawInactive === '1' || rawInactive === 'true';
    const fromQuery = Boolean(rawId);
    return { id, inactive, fromQuery };
  };

  const hasFocusMessageQuery = () => {
    const { id } = readFocusMessageQuery();
    return typeof id === 'number' && Number.isFinite(id) && id > 0;
  };

  const clearFocusMessageQuery = async () => {
    const query = { ...params.routeQuery() } as Record<string, any>;
    delete query.focusMessage;
    delete query.focusInactive;
    await params.replaceRouteQuery(query);
  };

  const handleFocusMessage = async () => {
    const { id, inactive, fromQuery } = readFocusMessageQuery();
    if (!fromQuery) return;

    if (!id || !Number.isFinite(id) || !params.chatId.value) {
      await clearFocusMessageQuery();
      return;
    }

    if (inactive && !params.readOnly.value) {
      try {
        const payload = await api.post<{ branch: ChatBranchMessage[] }>(
          `/api/bff/chats/${params.chatId.value}/activate-branch`,
          {
            message_id: id,
          }
        );
        params.branch.value = payload.branch || [];
      } catch (error) {
        console.error(error);
      }
    }

    await nextTick();
    await waitForAnimationFrame();
    handleBranchItemClick(id);
    rerunBranchSearch();
    await clearFocusMessageQuery();
  };

  const resetForChatChange = () => {
    clearBranchSearchTimer();
    branchSearchTerm.value = '';
    resetBranchSearch();
  };

  const openContextBlockEditor = (blockId: number) => {
    const ids = Array.from(
      new Set((linkedBlocks.value || []).map((item) => item.block?.id).filter((id): id is number => typeof id === 'number'))
    );
    const returnTo = params.routeFullPath();
    const navKey = createRecordset(ids, { returnTo });
    params.stackOpen({ path: `/catalogs/knowledge-blocks/${blockId}`, query: { navKey, returnTo } });
  };

  const openContextToolEditor = (toolInstanceId: number) => {
    const ids = Array.from(
      new Set(
        (activeToolBindings.value || [])
          .map((binding) => binding.tool_instance_id)
          .filter((id): id is number => typeof id === 'number' && id > 0)
      )
    );
    const returnTo = params.routeFullPath();
    const navKey = createRecordset(ids, { returnTo });
    params.stackOpen({ path: `/catalogs/tools/${toolInstanceId}`, query: { navKey, returnTo } });
  };

  const dispose = () => {
    clearBranchSearchTimer();
    messageRefs.clear();
  };

  return {
    linkedBlocks,
    promptTokenCount,
    historyTokenCount,
    totalTokenCount,
    isAgentHistoryMode,
    agentContextTokenCount,
    showContextUsageIndicator,
    contextUsagePercentRounded,
    contextUsageTitle,
    isContextSoftLimitReached,
    contextUsagePercent,
    branchSearchTerm,
    hasBranchSearch,
    branchSearchLoading,
    branchSearchError,
    branchSearchResults,
    botToolsLoading,
    botToolsError,
    activeToolInstances,
    activeToolBindings,
    hydrate,
    hasFocusMessageQuery,
    handleFocusMessage,
    rerunBranchSearch,
    resetForChatChange,
    formatStepMetric,
    searchHitMeta,
    messageMetaLabel,
    preview,
    formatBlockVersion,
    hasBlockVersion,
    chatWindowRef,
    setMessageRef,
    scrollToLastMessage,
    handleBranchItemClick,
    handleSearchResultClick,
    openContextBlockEditor,
    openContextToolEditor,
    dispose,
  };
}
