import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';

import { api, isHttpError } from '@/api/client';
import { jsonApiList, relationshipId, toIntId, type JsonApiResource } from '@/api/jsonApi';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import { useKnowledgeBlockNewDraft } from '@/features/catalogs/model/useKnowledgeBlockNewDraft';
import { parseImageAsset } from '@/features/media/image';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import { useChatUiChrome } from '@/features/chat/model/useChatUiChrome';
import {
  SOURCE_LABELS,
  type ActiveToolInstance,
  type BranchSearchResults,
  type ChatMessageSearchHit,
  type LinkedBlock,
} from '@/features/chat/types';
import {
  buildMessageContentFileUrl,
  createPendingChatFiles,
  describeChatUploadPolicy,
  getAttachmentMimeType,
  getAttachmentName,
  getAttachmentPreviewKind,
  mapContentToExistingAttachment,
  resolveChatUploadPolicy,
  validateFilesForChatUpload,
  type ExistingChatAttachment,
  type PendingChatFile,
} from '@/features/chat/attachments';
import { copyTextWithFallback } from '@/utils/clipboard';
import { displayTimestampIso, formatRelativeDateTime } from '@/utils/dates';
import type {
  Bot,
  Chat,
  ChatBranchMessage,
  ChatMessageContent,
  ChatKnowledgeBlock,
  ChatMessageStep,
  ChatVariable,
  KnowledgeBlock,
  LlmConfiguration,
} from '@/types/api';

type Counters = {
  prompt_token_count: number;
  history_token_count: number;
  history_message_count: number;
  total_token_count: number;
};

type PromptBinding = {
  id: number;
  enabled: boolean;
  sequence: number;
  knowledge_block: KnowledgeBlock | null;
};

type ChatStatePayload = {
  chat: Chat;
  branch: ChatBranchMessage[];
  chat_blocks: ChatKnowledgeBlock[];
  prompt_sources: {
    bot: PromptBinding[];
    chat: PromptBinding[];
    configuration: PromptBinding[];
    user: PromptBinding[];
  };
  compiled_prompt_text: string | null;
  counters: Counters;
  options: {
    bots: Bot[];
    llm_configurations: LlmConfiguration[];
    knowledge_blocks: KnowledgeBlock[];
  };
  active_generation_message_id: number | null;
};

type PollResponse = {
  message_id: number;
  runtime: boolean;
  status: string;
  current_step: ChatMessageStep | null;
  steps?: ChatMessageStep[] | null;
  finished_at?: string | null;
  token_count?: number | null;
  error_detail?: string | null;
};

type ChatBlockLink = {
  id: number;
  block: number;
  enabled: boolean;
  sequence: number;
};

type ToolBindingRow = {
  id: number;
  alias: string;
  enabled: boolean;
  sequence: number;
  sharing_mode: string;
  tool_instance_id: number | null;
};

const normalizeText = (value: unknown) => String(value ?? '').trim();

const jsonStable = (value: unknown) => {
  try {
    return JSON.stringify(value);
  } catch {
    return '';
  }
};

const normalizeVariablesForCompare = (vars: Partial<ChatVariable>[]) => {
  return [...(vars || [])]
    .map((v) => ({ key: normalizeText(v.key), value: String(v.value ?? '') }))
    .filter((v) => v.key !== '' || v.value !== '')
    .sort((a, b) => a.key.localeCompare(b.key));
};

const normalizeChatBlocksForCompare = (blocks: ChatBlockLink[]) => {
  return [...(blocks || [])]
    .map((b) => ({ block: b.block, enabled: Boolean(b.enabled), sequence: Number(b.sequence) || 0 }))
    .sort((a, b) => a.sequence - b.sequence || a.block - b.block);
};

const normalizeIdList = (ids: number[] | null | undefined) =>
  Array.from(new Set((ids || []).filter((id): id is number => typeof id === 'number' && id > 0))).sort((a, b) => a - b);

const parseToolBindingRow = (resource: JsonApiResource): ToolBindingRow | null => {
  const id = toIntId(resource.id);
  if (!id) return null;

  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const alias = String(attrs.alias || '').trim();
  const sharingMode = String(attrs.sharing_mode || 'shared').trim() || 'shared';
  const sequence =
    typeof attrs.sequence === 'number'
      ? attrs.sequence
      : Number.isFinite(Number(attrs.sequence))
        ? Number(attrs.sequence)
        : 0;
  const embeddedTool =
    attrs.tool_instance && typeof attrs.tool_instance === 'object'
      ? (attrs.tool_instance as Record<string, unknown>)
      : null;
  const toolInstanceId =
    relationshipId(resource, 'tool_instance') ??
    (typeof attrs.tool_instance_id === 'number'
      ? attrs.tool_instance_id
      : toIntId(attrs.tool_instance_id as string | number | null | undefined)) ??
    toIntId(embeddedTool?.id as string | number | null | undefined);

  return {
    id,
    alias,
    enabled: Boolean(attrs.enabled),
    sequence,
    sharing_mode: sharingMode,
    tool_instance_id: toolInstanceId,
  };
};

const parseToolInstanceMeta = (resource: JsonApiResource): ActiveToolInstance | null => {
  const id = toIntId(resource.id);
  if (!id) return null;

  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return {
    id,
    name: String(attrs.name || '').trim() || `Tool #${id}`,
    type: String(attrs.type || '').trim(),
    outlet_online: Boolean(attrs.outlet_online),
  };
};

export function useChatViewModel() {
  const route = useRoute();
  const router = useRouter();
  const stackNav = useStackNavigation();
  const stack = useNavigationStack();
  const chatId = computed(() => Number(route.params.id));

  const getQueryString = (value: unknown) =>
    Array.isArray(value) ? value[0] : typeof value === 'string' ? value : undefined;

  const readFocusMessageQuery = () => {
    const rawId = getQueryString((route.query as any).focusMessage);
    const rawInactive = getQueryString((route.query as any).focusInactive);
    const id = rawId ? Number(rawId) : null;
    const inactive = rawInactive === '1' || rawInactive === 'true';
    const fromQuery = Boolean(rawId);
    return { id, inactive, fromQuery };
  };

  const hasFocusMessageQuery = () => {
    const { id } = readFocusMessageQuery();
    return typeof id === 'number' && Number.isFinite(id) && id > 0;
  };

  const ui = useChatUiChrome();

  const loaded = ref(false);
  const loadError = ref('');

  const chat = ref<Chat | null>(null);
  const chatNote = ref('');
  const branch = ref<ChatBranchMessage[]>([]);
  const counters = ref<Counters>({
    prompt_token_count: 0,
    history_token_count: 0,
    history_message_count: 0,
    total_token_count: 0,
  });

  const promptSources = ref<ChatStatePayload['prompt_sources']>({
    bot: [],
    chat: [],
    configuration: [],
    user: [],
  });
  const compiledPromptText = ref('');

  const bots = ref<Bot[]>([]);
  const llmConfigurations = ref<LlmConfiguration[]>([]);
  const knowledgeBlocks = ref<KnowledgeBlock[]>([]);

  const selectedConfig = ref<number | ''>('');
  const configSyncStatus = ref<'synced' | 'pending' | 'error'>('synced');
  const configSyncError = ref('');
  const appliedConfig = computed<number | ''>(() => chat.value?.llm_configuration_id ?? '');
  const isConfigSyncPending = computed(() => configSyncStatus.value === 'pending');
  let configSyncToken = 0;
  const currentConfig = computed(() => {
    const cfgId = selectedConfig.value || chat.value?.llm_configuration_id || null;
    if (!cfgId) return null;
    return (llmConfigurations.value || []).find((c) => c.id === Number(cfgId)) || null;
  });

  const configLabel = (cfg: LlmConfiguration) => {
    const prefix = cfg.shared_incoming ? '📥 ' : cfg.shared_outgoing ? '📤 ' : '';
    return `${prefix}${cfg.label || `Config #${cfg.id}`}`;
  };
  const messageConfigLabel = (configId?: number | null) => {
    if (!configId) return '';
    const cfg = (llmConfigurations.value || []).find((item) => item.id === configId);
    return cfg ? configLabel(cfg) : `Config #${configId}`;
  };
  const editConfigLabel = computed(() => 'Edit configuration');

  const currentBotId = computed(() => chat.value?.bot_id ?? null);
  const currentBotInfo = computed(() => {
    const id = currentBotId.value;
    if (!id) return null;
    return (bots.value || []).find((b) => b.id === id) || null;
  });
  const currentBotName = computed(() => {
    const id = currentBotId.value;
    if (!id) return '';
    return currentBotInfo.value?.name || `Bot #${id}`;
  });
  const currentBotCompatibleTagIds = computed(() =>
    normalizeIdList(currentBotInfo.value?.compatible_configuration_tag_ids || [])
  );
  const selectableConfigs = computed(() => {
    const enabledConfigs = (llmConfigurations.value || []).filter((c) => c.enabled);
    if (!currentBotId.value || !currentBotCompatibleTagIds.value.length) return enabledConfigs;

    return enabledConfigs.filter((cfg) => {
      const configTagIds = normalizeIdList(cfg.tag_ids || []);
      return configTagIds.some((tagId) => currentBotCompatibleTagIds.value.includes(tagId));
    });
  });
  const fileUploadPolicy = computed(() =>
    resolveChatUploadPolicy(currentBotInfo.value, currentConfig.value)
  );
  const selectedDisabledConfigReason = computed<'disabled' | 'incompatible' | null>(() => {
    if (!selectedConfig.value) return null;

    const cfg = (llmConfigurations.value || []).find((c) => c.id === Number(selectedConfig.value)) || null;
    if (!cfg) return null;
    if (!cfg.enabled) return 'disabled';
    if (selectableConfigs.value.some((item) => item.id === cfg.id)) return null;
    if (!currentBotId.value || !currentBotCompatibleTagIds.value.length) return null;
    return 'incompatible';
  });
  const selectedDisabledConfig = computed(() => {
    if (!selectedConfig.value) return null;
    if (!selectedDisabledConfigReason.value) return null;
    return (llmConfigurations.value || []).find((c) => c.id === Number(selectedConfig.value)) || null;
  });
  const canAttachFiles = computed(() => fileUploadPolicy.value.allowsFiles);
  const fileInputAccept = computed(() => fileUploadPolicy.value.accept);
  const fileAttachTitle = computed(() => describeChatUploadPolicy(fileUploadPolicy.value));
  const fileDropHint = computed(() =>
    fileUploadPolicy.value.imagesOnly ? 'Drop images to attach' : 'Drop files to attach'
  );

  const showMissingToolsBanner = ref(false);
  const missingRequiredPerUserToolAliases = ref<string[]>([]);
  const pendingFiles = ref<PendingChatFile[]>([]);

  const leftOpen = ui.leftOpen;
  const rightOpen = ui.rightOpen;
  const leftTab = ui.leftTab;
  const isMobile = ui.isMobile;
  const menuOpen = ui.menuOpen;
  const menuStyle = ui.menuStyle;

  const gridColumns = ui.gridColumns;

  const menuRef = ui.menuRef;
  const menuAnchorRef = ui.menuAnchorRef;
  const menuButtonRef = ui.menuButtonRef;

  const setMenuRef = (el: Element | null) => {
    menuRef.value = el as HTMLElement | null;
  };

  const setMenuAnchorRef = (el: Element | null) => {
    menuAnchorRef.value = el as HTMLElement | null;
  };

  const setMenuButtonRef = (el: Element | null) => {
    menuButtonRef.value = el as HTMLElement | null;
  };

  const toggleMenu = () => ui.toggleMenu();
  const closeMenu = () => ui.closeMenu();
  const closeOverlays = () => ui.closeOverlays();

  watch(
    () => [leftOpen.value, rightOpen.value, leftTab.value],
    () => ui.persistPanelState(),
    { deep: false }
  );

  const linkedBlocks = computed<LinkedBlock[]>(() => {
    const buckets: Array<{ source: 'bot' | 'chat' | 'config' | 'user'; list: PromptBinding[] }> = [
      { source: 'bot', list: promptSources.value.bot || [] },
      { source: 'chat', list: promptSources.value.chat || [] },
      { source: 'config', list: promptSources.value.configuration || [] },
      { source: 'user', list: promptSources.value.user || [] },
    ];

    const items: LinkedBlock[] = [];
    for (const bucket of buckets) {
      for (const binding of bucket.list || []) {
        if (!binding?.enabled) continue;
        if (!binding.knowledge_block) continue;
        items.push({
          block: binding.knowledge_block,
          source: bucket.source,
          order: binding.sequence ?? 0,
        });
      }
    }

    return items.sort((a, b) => {
      if (a.source !== b.source) return a.source.localeCompare(b.source);
      return (a.order || 0) - (b.order || 0);
    });
  });

  const formatStepMetric = (value: unknown) => {
    if (value == null || value === '') return '—';
    return String(value);
  };

  const errorMessage = (error: unknown, fallback: string) => {
    if (isHttpError(error) && error.bodyJson && typeof (error.bodyJson as { error?: unknown }).error === 'string') {
      return String((error.bodyJson as { error?: unknown }).error);
    }

    return error instanceof Error ? error.message : fallback;
  };

  const promptTokenCount = computed(() =>
    linkedBlocks.value.reduce((sum, item) => sum + (item.block.token_count || 0), 0)
  );
  const historyTokenCount = computed(() =>
    branch.value.reduce((sum, msg) => sum + (msg.token_count || 0), 0)
  );
  const totalTokenCount = computed(() => promptTokenCount.value + historyTokenCount.value);

  const findLatestStepWithUsage = (messages: ChatBranchMessage[]) => {
    for (let i = messages.length - 1; i >= 0; i -= 1) {
      const steps = messages[i].steps || [];
      for (let j = steps.length - 1; j >= 0; j -= 1) {
        const step = steps[j];
        if (step.input_tokens != null || step.output_tokens != null) return step;
      }
    }
    return null;
  };

  const isAgentHistoryMode = computed(() => true);
  const agentContextTokenCount = computed<number | null>(() => {
    const step = findLatestStepWithUsage(branch.value);
    if (!step) return null;
    const input = typeof step.input_tokens === 'number' ? step.input_tokens : 0;
    const output = typeof step.output_tokens === 'number' ? step.output_tokens : 0;
    return input + output;
  });

  const contextLengthTokens = computed<number | null>(() => {
    const len = currentConfig.value?.context_length;
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
    const soft = currentBotInfo.value?.context_soft_limit_percent;
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
    if (!chatId.value) return;
    const query = term.trim();
    if (!query) {
      resetBranchSearch();
      return;
    }

    const seq = ++branchSearchSeq;
    branchSearchLoading.value = true;
    branchSearchError.value = '';

    try {
      const params = new URLSearchParams();
      params.set('q', query);
      const payload = await api.get<BranchSearchResults>(`/api/bff/chats/${chatId.value}/search?${params.toString()}`);
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
      runBranchSearch(query);
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

  const searchHitMeta = (hit: ChatMessageSearchHit) => {
    const time = formatRelativeDateTime(displayTimestampIso(hit));
    const cfgLabel =
      hit.role === 'assistant' ? messageConfigLabel(hit.llm_configuration_id ?? null) : '';
    if (time && cfgLabel) return `${time} (${cfgLabel})`;
    if (time) return time;
    if (cfgLabel) return cfgLabel;
    return hit.role === 'user' ? 'User' : 'Assistant';
  };
  const preview = (text: string) => {
    const normalized = String(text || '').replace(/\s+/g, ' ').trim();
    if (!normalized) return '';
    const limit = isMobile.value ? 100 : 160;
    if (normalized.length <= limit) return normalized;
    return `${normalized.slice(0, limit)}…`;
  };

  const formatBlockVersion = (value: unknown) => {
    if (value == null) return '';
    if (typeof value === 'number') {
      return Number.isFinite(value) && value > 0 ? `v${value}` : '';
    }
    const text = String(value).trim();
    if (!text) return '';
    if (/^v\\d+/i.test(text)) return text;
    if (/^\\d+$/.test(text)) return `v${text}`;
    return text;
  };

  const hasBlockVersion = (value: unknown) => formatBlockVersion(value) !== '';

  const botToolsLoading = ref(false);
  const botToolsError = ref('');
  const activeToolInstances = ref<ActiveToolInstance[]>([]);
  const botToolsRequestToken = ref(0);

  const loadBotToolsState = async (botId: number | null) => {
    const token = botToolsRequestToken.value + 1;
    botToolsRequestToken.value = token;

    if (!botId) {
      botToolsLoading.value = false;
      botToolsError.value = '';
      activeToolInstances.value = [];
      missingRequiredPerUserToolAliases.value = [];
      showMissingToolsBanner.value = false;
      return;
    }

    botToolsLoading.value = true;
    botToolsError.value = '';

    try {
      const botBindingsQuery = new URLSearchParams();
      botBindingsQuery.set('filter[bot_id]', String(botId));
      botBindingsQuery.set('sort', 'sequence');
      botBindingsQuery.set(
        'fields[bot-tool-bindings]',
        'alias,enabled,sequence,sharing_mode,tool_instance'
      );

      const userBindingsQuery = new URLSearchParams();
      userBindingsQuery.set('filter[bot_id]', String(botId));
      userBindingsQuery.set('sort', 'sequence');
      userBindingsQuery.set('fields[bot-user-tool-bindings]', 'alias,enabled,sequence,tool_instance');

      const toolsQuery = new URLSearchParams();
      toolsQuery.set('sort', 'name');
      toolsQuery.set('fields[tool-instances]', 'name,type,outlet_online');

      const [botBindingsPayload, userBindingsPayload, toolInstancesPayload] = await Promise.all([
        jsonApiList('/api/ash/bot-tool-bindings', botBindingsQuery),
        jsonApiList('/api/ash/bot-user-tool-bindings', userBindingsQuery),
        jsonApiList('/api/ash/tool-instances', toolsQuery),
      ]);

      if (botToolsRequestToken.value !== token) return;

      const botBindings = (botBindingsPayload.data || [])
        .map(parseToolBindingRow)
        .filter((row): row is ToolBindingRow => Boolean(row))
        .filter((row) => row.enabled && row.alias !== '')
        .sort((a, b) => a.sequence - b.sequence || a.id - b.id);

      const userBindings = (userBindingsPayload.data || [])
        .map(parseToolBindingRow)
        .filter((row): row is ToolBindingRow => Boolean(row))
        .filter((row) => row.enabled && row.alias !== '')
        .sort((a, b) => a.sequence - b.sequence || a.id - b.id);

      const toolById = new Map<number, ActiveToolInstance>();
      for (const resource of toolInstancesPayload.data || []) {
        const parsed = parseToolInstanceMeta(resource);
        if (!parsed) continue;
        toolById.set(parsed.id, parsed);
      }

      const aliasToToolId = new Map<string, number>();
      const missingAliases = new Set<string>();

      for (const binding of botBindings) {
        if (binding.sharing_mode === 'per_user') {
          missingAliases.add(binding.alias);
          continue;
        }

        if (!binding.tool_instance_id) continue;
        aliasToToolId.set(binding.alias, binding.tool_instance_id);
      }

      for (const binding of userBindings) {
        if (!binding.tool_instance_id) continue;
        aliasToToolId.set(binding.alias, binding.tool_instance_id);
        missingAliases.delete(binding.alias);
      }

      const seenToolIds = new Set<number>();
      const nextTools: ActiveToolInstance[] = [];

      for (const toolId of aliasToToolId.values()) {
        if (seenToolIds.has(toolId)) continue;
        seenToolIds.add(toolId);
        const tool = toolById.get(toolId);
        nextTools.push({
          id: toolId,
          name: tool?.name || `Tool #${toolId}`,
          type: tool?.type || '',
          outlet_online: Boolean(tool?.outlet_online),
        });
      }

      activeToolInstances.value = nextTools;
      missingRequiredPerUserToolAliases.value = Array.from(missingAliases).sort((a, b) => a.localeCompare(b));
      showMissingToolsBanner.value = missingRequiredPerUserToolAliases.value.length > 0;
    } catch (error) {
      if (botToolsRequestToken.value !== token) return;
      console.error(error);
      botToolsError.value = error instanceof Error ? error.message : 'Failed to load tools.';
      activeToolInstances.value = [];
      missingRequiredPerUserToolAliases.value = [];
      showMissingToolsBanner.value = false;
    } finally {
      if (botToolsRequestToken.value === token) {
        botToolsLoading.value = false;
      }
    }
  };

  const messageMetaLabel = (msg: ChatBranchMessage) => {
    const time = formatRelativeDateTime(displayTimestampIso(msg));
    const cfgLabel =
      msg.role === 'assistant' ? messageConfigLabel(msg.llm_configuration_id) : '';
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
    const last = branch.value[branch.value.length - 1];
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
    if (isMobile.value) {
      leftOpen.value = false;
    }
  };

  const handleSearchResultClick = async (hit: ChatMessageSearchHit, inactive: boolean) => {
    if (!hit?.id) return;

    if (!inactive) {
      handleBranchItemClick(hit.id);
      return;
    }

    if (!chatId.value) return;

    try {
      const payload = await api.post<{ branch: ChatBranchMessage[] }>(
        `/api/bff/chats/${chatId.value}/activate-branch`,
        {
          message_id: hit.id,
        }
      );

      branch.value = payload.branch || [];

      await nextTick();
      handleBranchItemClick(hit.id);

      if (hasBranchSearch.value) {
        runBranchSearch(branchSearchTerm.value.trim());
      }
    } catch (error) {
      console.error(error);
      alert('Failed to activate the branch.');
    }
  };

  const clearFocusMessageQuery = async () => {
    const query: Record<string, any> = { ...(route.query as any) };
    delete query.focusMessage;
    delete query.focusInactive;
    await router.replace({ path: route.path, query });
  };

  const handleFocusMessage = async () => {
    const { id, inactive, fromQuery } = readFocusMessageQuery();
    if (!fromQuery) return;

    if (!id || !Number.isFinite(id) || !chatId.value) {
      await clearFocusMessageQuery();
      return;
    }

    if (inactive) {
      try {
        const payload = await api.post<{ branch: ChatBranchMessage[] }>(
          `/api/bff/chats/${chatId.value}/activate-branch`,
          {
            message_id: id,
          }
        );
        branch.value = payload.branch || [];
      } catch (error) {
        console.error(error);
      }
    }

    await nextTick();
    await waitForAnimationFrame();
    handleBranchItemClick(id);

    if (hasBranchSearch.value) {
      runBranchSearch(branchSearchTerm.value.trim());
    }

    await clearFocusMessageQuery();
  };

  const copiedMessageId = ref<number | null>(null);
  const retryingMessageId = ref<number | null>(null);
  const branchingAssistantId = ref<number | null>(null);

  const joinTextContents = (contents: unknown) => {
    const list = Array.isArray(contents) ? contents : [];
    return list
      .filter((c) => c && typeof c === 'object' && (c as { kind?: unknown }).kind === 'text')
      .map((c) => String((c as { content_text?: unknown }).content_text ?? ''))
      .join('');
  };

  const messagePrimaryText = (msg: ChatBranchMessage) => {
    const wantedType = msg.role === 'user' ? 'input' : 'answer';
    const steps = msg.steps || [];
    const items = steps.flatMap((step) => step.items || []);
    return items
      .filter((item) => item && item.type === wantedType)
      .map((item) => joinTextContents(item.contents))
      .filter((text) => String(text).trim() !== '')
      .join('\n\n');
  };

  const copyMessage = async (msg: ChatBranchMessage) => {
    try {
      const copied = await copyTextWithFallback(messagePrimaryText(msg), {
        promptLabel: 'Copy the message text manually:',
      });
      if (!copied) return;
      copiedMessageId.value = msg.id;
      window.setTimeout(() => {
        if (copiedMessageId.value === msg.id) copiedMessageId.value = null;
      }, 1200);
    } catch (error) {
      console.warn(error);
    }
  };

  const confirm = (message: string) => window.confirm(message);
  const alert = (message: string) => window.alert(message);

  const deletingMessageId = ref<number | null>(null);

  const canDeleteMessage = (msg: ChatBranchMessage, _idx: number) => {
    if (!msg.id) return false;
    if (msg.status === 'generating') return false;
    if (deletingMessageId.value === msg.id) return false;
    return true;
  };

  const deleteMessageTitle = (msg: ChatBranchMessage, _idx: number) => {
    if (!msg.id) return 'Message is not saved yet';
    if (msg.status === 'generating') return 'Cannot delete while generating';
    if (deletingMessageId.value === msg.id) return 'Deleting…';
    return 'Delete';
  };

  const confirmAndDeleteMessage = async (msg: ChatBranchMessage, idx: number) => {
    if (!msg.id) return;
    if (!canDeleteMessage(msg, idx)) {
      alert(deleteMessageTitle(msg, idx));
      return;
    }

    const ok = confirm('Delete this message?');
    if (!ok) return;

    deletingMessageId.value = msg.id;
    try {
      const payload = await api.post<{ branch: ChatBranchMessage[] }>(
        `/api/bff/chat-messages/${msg.id}/delete`,
        {}
      );
      branch.value = payload.branch || [];
    } catch (error) {
      console.error(error);
      alert('Failed to delete the message.');
    } finally {
      if (deletingMessageId.value === msg.id) deletingMessageId.value = null;
    }
  };

  const workingOpenById = ref<Set<number>>(new Set());
  const isWorkingOpen = (id: number | null | undefined) => {
    if (!id) return false;
    return workingOpenById.value.has(id);
  };

  const toggleWorking = (id: number | null | undefined) => {
    if (!id) return;
    const next = new Set(workingOpenById.value);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    workingOpenById.value = next;
  };

  const activeGenerationId = ref<number | null>(null);
  const cancelingGenerationId = ref<number | null>(null);

  const draft = ref('');
  const sending = ref(false);

  let pollTimer: number | null = null;
  let pollingToken = 0;
  let pollAbortController: AbortController | null = null;
  let lastResumeSyncAt = 0;

  const generatingMessageIdInBranch = computed<number | null>(() => {
    const list = branch.value || [];
    for (let i = list.length - 1; i >= 0; i -= 1) {
      const msg = list[i];
      if (msg?.status === 'generating') return msg.id;
    }
    return null;
  });

  const stopPolling = () => {
    pollingToken += 1;
    if (pollTimer != null) {
      window.clearTimeout(pollTimer);
      pollTimer = null;
    }
    if (pollAbortController) {
      pollAbortController.abort();
      pollAbortController = null;
    }
  };

  const upsertRuntimeStepIntoSteps = (
    steps: ChatMessageStep[] | null | undefined,
    runtimeStep: ChatMessageStep
  ): ChatMessageStep[] => {
    const list = steps || [];
    if (!list.length) return [runtimeStep];

    const runtimeSeq = typeof runtimeStep.sequence === 'number' ? runtimeStep.sequence : null;

    if (runtimeSeq == null) {
      return [...list, runtimeStep];
    }

    for (let i = list.length - 1; i >= 0; i -= 1) {
      const candidate = list[i];
      if (typeof candidate?.sequence === 'number' && candidate.sequence === runtimeSeq) {
        return [...list.slice(0, i), runtimeStep, ...list.slice(i + 1)];
      }
    }

    return [...list, runtimeStep];
  };

  const mergePolledSteps = (
    currentSteps: ChatMessageStep[] | null | undefined,
    persistedSteps: ChatMessageStep[] | null | undefined,
    runtimeStep: ChatMessageStep | null | undefined
  ): ChatMessageStep[] => {
    const base = Array.isArray(persistedSteps) && persistedSteps.length > 0 ? persistedSteps : currentSteps || [];

    if (runtimeStep) {
      return upsertRuntimeStepIntoSteps(base, runtimeStep);
    }

    return [...base];
  };

  const updateBranchMessage = (messageId: number, patch: Partial<ChatBranchMessage>) => {
    const idx = branch.value.findIndex((m) => m.id === messageId);
    if (idx === -1) return;
    branch.value[idx] = { ...branch.value[idx], ...patch };
  };

  const refreshBranchFromServer = async () => {
    if (!chatId.value) return;
    const payload = await api.get<ChatStatePayload>(`/api/bff/chats/${chatId.value}/state`);
    branch.value = payload.branch || [];
    counters.value = payload.counters || counters.value;
  };

  const refreshPromptContextFromServer = async () => {
    if (!chatId.value) return;
    const payload = await api.get<ChatStatePayload>(`/api/bff/chats/${chatId.value}/state`);
    promptSources.value = payload.prompt_sources || promptSources.value;
    compiledPromptText.value = payload.compiled_prompt_text || '';
    counters.value = payload.counters || counters.value;
  };

  const pollOnce = async (messageId: number, token: number) => {
    const controller = new AbortController();
    pollAbortController = controller;

    const timeoutHandle = window.setTimeout(() => controller.abort(), 25_000);

    try {
      const response = await api.get<PollResponse>(`/api/bff/chat-messages/${messageId}/poll`, {
        signal: controller.signal,
      });

      if (pollingToken !== token) return false;

      const current = branch.value.find((m) => m.id === messageId) || null;

      if (current) {
        const patch: Partial<ChatBranchMessage> = {
          status: response.status as ChatBranchMessage['status'],
          finished_at: response.finished_at ?? undefined,
          error_detail: response.error_detail ?? undefined,
        };

        if (typeof response.token_count === 'number') {
          patch.token_count = response.token_count;
        }

        const mergedSteps = mergePolledSteps(current.steps || [], response.steps || [], response.current_step);
        if (mergedSteps.length > 0) {
          patch.steps = mergedSteps;
        }

        updateBranchMessage(messageId, patch);
      }

      const doneStatuses = new Set(['done', 'canceled', 'error']);
      if (doneStatuses.has(response.status)) {
        if (activeGenerationId.value === messageId) activeGenerationId.value = null;
        if (cancelingGenerationId.value === messageId) cancelingGenerationId.value = null;
        stopPolling();
        return false;
      }

      return true;
    } finally {
      window.clearTimeout(timeoutHandle);
      if (pollAbortController === controller) pollAbortController = null;
    }
  };

  const startPolling = async (messageId: number) => {
    stopPolling();
    activeGenerationId.value = messageId;

    const token = pollingToken;

    const tick = async () => {
      if (pollingToken !== token) return;
      try {
        const keepGoing = await pollOnce(messageId, token);
        if (keepGoing && activeGenerationId.value === messageId && pollingToken === token) {
          pollTimer = window.setTimeout(tick, 500);
        }
      } catch (error) {
        if (pollingToken !== token) return;
        if (error instanceof DOMException && error.name === 'AbortError') return;
        console.warn(error);
        if (activeGenerationId.value === messageId && pollingToken === token) {
          pollTimer = window.setTimeout(tick, 1500);
        }
      }
    };

    await tick();
  };

  watch(
    () => generatingMessageIdInBranch.value,
    (messageId) => {
      if (messageId) {
        if (activeGenerationId.value !== messageId) {
          void startPolling(messageId);
        }
      } else if (activeGenerationId.value != null) {
        activeGenerationId.value = null;
        cancelingGenerationId.value = null;
        stopPolling();
      }
    }
  );

  const resumeSyncIfNeeded = () => {
    const messageId = activeGenerationId.value || generatingMessageIdInBranch.value;
    if (!messageId) return;

    const now = Date.now();
    if (now - lastResumeSyncAt < 1000) return;
    lastResumeSyncAt = now;

    void startPolling(messageId);
  };

  const handleVisibilityChange = () => {
    if (document.visibilityState !== 'visible') return;
    resumeSyncIfNeeded();
  };

  const handlePageShow = () => {
    resumeSyncIfNeeded();
  };

  const handleFocus = () => {
    resumeSyncIfNeeded();
  };

  const send = async () => {
    if (!chatId.value || sending.value) return;
    if (activeGenerationId.value) return;
    if (isConfigSyncPending.value) {
      loadError.value = 'Configuration change is still syncing. Please wait.';
      return;
    }

    sending.value = true;
    loadError.value = '';

    try {
      const content = draft.value;
      const hasUserText = content !== '';
      const hasPendingFiles = pendingFiles.value.length > 0;

      const payload =
        hasUserText || hasPendingFiles
          ? hasPendingFiles
            ? await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
                `/api/bff/chats/${chatId.value}/send`,
                await buildSendFormData(content, pendingFiles.value)
              )
            : await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
                `/api/bff/chats/${chatId.value}/send`,
                { content }
              )
          : await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
              `/api/bff/chats/${chatId.value}/generate`,
              {}
            );

      branch.value = payload.branch || [];
      if (hasUserText) draft.value = '';
      if (hasPendingFiles) pendingFiles.value = [];

      const messageId = payload.generation?.message_id;
      if (messageId) {
        await startPolling(messageId);
      }

      void scrollToLastMessage({ behavior: 'smooth', block: 'end' });
    } catch (error) {
      console.error(error);
      loadError.value = errorMessage(error, 'Failed to send message.');
    } finally {
      sending.value = false;
    }
  };

  const cancelActiveGeneration = async () => {
    const messageId = activeGenerationId.value;
    if (!messageId || cancelingGenerationId.value === messageId) return;
    cancelingGenerationId.value = messageId;

    try {
      await api.post(`/api/bff/chat-messages/${messageId}/cancel`, {});
    } catch (error) {
      console.error(error);
      alert('Failed to cancel generation.');
    } finally {
      if (cancelingGenerationId.value === messageId) cancelingGenerationId.value = null;
    }
  };

  const handleCancelPointerDown = (event: PointerEvent) => {
    if (!activeGenerationId.value) return;
    event.preventDefault();
  };

  const onPendingFilesSelected = (event: Event) => {
    const input = event.target as HTMLInputElement | null;
    addPendingFiles(Array.from(input?.files || []));
    if (input) input.value = '';
  };

  const addPendingFiles = (files: File[]) => {
    if (!files.length) return;
    const { accepted, errors } = validateFilesForChatUpload(files, fileUploadPolicy.value);

    if (accepted.length > 0) {
      pendingFiles.value = [...pendingFiles.value, ...createPendingChatFiles(accepted)];
    }

    loadError.value = errors[0] || '';
  };

  const removePendingFile = (id: string) => {
    pendingFiles.value = pendingFiles.value.filter((item) => item.id !== id);
  };

  const retryLastStep = async (msg: ChatBranchMessage) => {
    const messageId = msg.id;
    if (!chatId.value || !messageId) return;
    if (retryingMessageId.value === messageId) return;

    retryingMessageId.value = messageId;
    loadError.value = '';

    try {
      const payload = await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
        `/api/bff/chat-messages/${messageId}/retry-last-step`,
        {}
      );

      branch.value = payload.branch || [];

      const generationId = payload.generation?.message_id;
      if (generationId) {
        await startPolling(generationId);
      }

      void scrollToLastMessage({ behavior: 'smooth', block: 'end' });
    } catch (error) {
      console.error(error);
      alert('Failed to retry the last step.');
    } finally {
      if (retryingMessageId.value === messageId) retryingMessageId.value = null;
    }
  };

  const switchBranchHandler = async (
    messageId: number,
    direction?: 'prev' | 'next',
    targetId?: number
  ) => {
    if (!chatId.value) return;
    try {
      const payload = await api.post<{ branch: ChatBranchMessage[] }>(
        `/api/bff/chats/${chatId.value}/switch-branch`,
        {
          message_id: messageId,
          direction,
          target_id: targetId,
        }
      );
      branch.value = payload.branch || [];
      if (hasBranchSearch.value) {
        runBranchSearch(branchSearchTerm.value.trim());
      }
    } catch (error) {
      console.error(error);
    }
  };

  const editingMessage = ref<ChatBranchMessage | null>(null);
  const modalMode = ref<'edit' | 'branch'>('edit');
  const editContentIds = ref<number[]>([]);
  const editContents = ref<string[]>([]);
  const editExistingAttachments = ref<ExistingChatAttachment[]>([]);
  const editRemovedAttachmentIds = ref<number[]>([]);
  const editPendingFiles = ref<PendingChatFile[]>([]);
  const editError = ref('');
  const savingEdit = ref(false);

  const extractEditableTextContents = (msg: ChatBranchMessage) => {
    const wantedType = msg.role === 'user' ? 'input' : 'answer';
    const targets: Array<{ id: number; sequence: number; text: string }> = [];

    const steps = msg.steps || [];
    for (const step of [...steps].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0))) {
      const items = step.items || [];
      for (const item of [...items].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0))) {
        if (item.type !== wantedType) continue;

        const contents = item.contents || [];
        for (const content of [...contents].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0))) {
          if (content.kind !== 'text') continue;
          if (typeof content.id !== 'number') continue;
          targets.push({
            id: content.id,
            sequence: content.sequence ?? 0,
            text: String(content.content_text ?? ''),
          });
        }
      }
    }

    return targets;
  };

  const extractEditableMediaContents = (msg: ChatBranchMessage) => {
    if (!msg.id) return [];

    const wantedType = msg.role === 'user' ? 'input' : 'artifact';
    const attachments: ExistingChatAttachment[] = [];

    const steps = msg.steps || [];
    for (const step of [...steps].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0))) {
      const items = step.items || [];
      for (const item of [...items].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0))) {
        if (item.type !== wantedType) continue;

        const contents = item.contents || [];
        for (const content of [...contents].sort((a, b) => (a.sequence ?? 0) - (b.sequence ?? 0))) {
          const attachment = mapContentToExistingAttachment(content, msg.id);
          if (attachment) attachments.push(attachment);
        }
      }
    }

    return attachments;
  };

  const startEdit = (msg: ChatBranchMessage) => {
    if (!msg.id) return;
    const targets = extractEditableTextContents(msg);
    const attachments = extractEditableMediaContents(msg);

    if (targets.length === 0 && attachments.length === 0) {
      alert('No editable text content found for this message.');
      return;
    }

    editingMessage.value = msg;
    modalMode.value = 'edit';
    editContentIds.value = targets.map((t) => t.id);
    editContents.value = targets.map((t) => t.text);
    editExistingAttachments.value = attachments;
    editRemovedAttachmentIds.value = [];
    editPendingFiles.value = [];
    editError.value = '';
  };

  const branchFromAssistant = async (msg: ChatBranchMessage) => {
    if (!msg.id || !chatId.value) return;
    if (branchingAssistantId.value === msg.id) return;
    if (isConfigSyncPending.value) {
      alert('Configuration change is still syncing. Please wait before starting a new generation.');
      return;
    }

    const parentId = msg.parent_id ?? null;
    if (!parentId) {
      alert('Cannot branch: missing parent message.');
      return;
    }

    branchingAssistantId.value = msg.id;
    try {
      const payload = await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
        `/api/bff/chats/${chatId.value}/generate`,
        { parent_id: parentId }
      );
      branch.value = payload.branch || [];
      const messageId = payload.generation?.message_id;
      if (messageId) {
        await startPolling(messageId);
      }
    } catch (error) {
      console.error(error);
      alert('Failed to branch from assistant message.');
    } finally {
      branchingAssistantId.value = null;
    }
  };

  const startBranch = (msg: ChatBranchMessage) => {
    if (!msg.id) return;
    if (msg.role === 'user') {
      const attachments = extractEditableMediaContents(msg);
      editingMessage.value = msg;
      modalMode.value = 'branch';
      editContentIds.value = [];
      editContents.value = [messagePrimaryText(msg)];
      editExistingAttachments.value = attachments;
      editRemovedAttachmentIds.value = [];
      editPendingFiles.value = [];
      editError.value = '';
      return;
    }

    void branchFromAssistant(msg);
  };

  const cancelEdit = () => {
    editingMessage.value = null;
    editContentIds.value = [];
    editContents.value = [];
    editExistingAttachments.value = [];
    editRemovedAttachmentIds.value = [];
    editPendingFiles.value = [];
    editError.value = '';
  };

  const removeEditExistingAttachment = (contentId: number) => {
    editRemovedAttachmentIds.value = [...new Set([...editRemovedAttachmentIds.value, contentId])];
    editExistingAttachments.value = editExistingAttachments.value.filter((item) => item.id !== contentId);
  };

  const addEditPendingFiles = (files: File[]) => {
    if (!files.length) return;
    const { accepted, errors } = validateFilesForChatUpload(files, fileUploadPolicy.value);

    if (accepted.length > 0) {
      editPendingFiles.value = [...editPendingFiles.value, ...createPendingChatFiles(accepted)];
    }

    editError.value = errors[0] || '';
  };

  const removeEditPendingFile = (id: string) => {
    editPendingFiles.value = editPendingFiles.value.filter((item) => item.id !== id);
  };

  const saveEdit = async () => {
    if (!editingMessage.value?.id || savingEdit.value) return;
    savingEdit.value = true;
    editError.value = '';
    try {
      if (modalMode.value === 'edit') {
        const updates = editContentIds.value.map((id, idx) => ({
          id,
          content_text: editContents.value[idx] ?? '',
        }));

        const hasTextUpdates = updates.length > 0;
        const updatePayload =
          editPendingFiles.value.length > 0
            ? buildMessageUpdateFormData(
                hasTextUpdates ? updates : null,
                editRemovedAttachmentIds.value,
                editPendingFiles.value
              )
            : {
                ...(hasTextUpdates ? { contents: updates } : {}),
                ...(editRemovedAttachmentIds.value.length > 0
                  ? { remove_content_ids: editRemovedAttachmentIds.value }
                  : {}),
              };

        const payload = await api.patch<{ branch: ChatBranchMessage[] }>(
          `/api/bff/chat-messages/${editingMessage.value.id}`,
          updatePayload
        );
        branch.value = payload.branch || [];
        cancelEdit();
      } else {
        if (isConfigSyncPending.value) {
          alert('Configuration change is still syncing. Please wait before starting a new generation.');
          return;
        }
        const parentId = editingMessage.value.parent_id ?? null;
        const hasBranchFiles =
          editExistingAttachments.value.length > 0 || editPendingFiles.value.length > 0;
        const payload = await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
          `/api/bff/chats/${chatId.value}/send`,
          hasBranchFiles
            ? await buildSendFormData(
                editContents.value[0] ?? '',
                editPendingFiles.value,
                editExistingAttachments.value,
                parentId
              )
            : { content: editContents.value[0] ?? '', parent_id: parentId }
        );
        branch.value = payload.branch || [];
        cancelEdit();

        const messageId = payload.generation?.message_id;
        if (messageId) {
          await startPolling(messageId);
        }
      }
    } catch (error) {
      console.error(error);
      editError.value =
        modalMode.value === 'edit'
          ? errorMessage(error, 'Failed to save the message.')
          : errorMessage(error, 'Failed to branch.');
      alert(editError.value);
    } finally {
      savingEdit.value = false;
    }
  };

  const promptModalOpen = ref(false);
  const promptLoading = ref(false);
  const promptError = ref('');
  const promptText = ref('');

  const openPromptModal = async () => {
    promptModalOpen.value = true;
    promptLoading.value = false;
    promptError.value = '';
    promptText.value = compiledPromptText.value || '';
  };

  const closePromptModal = () => {
    promptModalOpen.value = false;
    promptLoading.value = false;
    promptError.value = '';
  };

  const noteModalOpen = ref(false);
  const noteModalValue = ref('');
  const savingNote = ref(false);

  const openNoteModal = () => {
    noteModalValue.value = chatNote.value || '';
    noteModalOpen.value = true;
  };

  const closeNoteModal = () => {
    noteModalOpen.value = false;
  };

  const saveNote = async () => {
    if (!chatId.value || savingNote.value) return;
    savingNote.value = true;
    try {
      const nextNote = noteModalValue.value.trim();
      await api.patch(`/api/bff/chats/${chatId.value}`, { note: nextNote });
      chatNote.value = nextNote;
      closeNoteModal();
    } catch (error) {
      console.error(error);
      alert('Failed to save note.');
    } finally {
      savingNote.value = false;
    }
  };

  const fetchStepRawPayload = async (payload: {
    messageId: number;
    stepId: number;
    kind: 'request' | 'response';
  }) => {
    if (!payload.stepId || payload.stepId <= 0) {
      throw new Error('Step is not available');
    }

    const params = new URLSearchParams();
    params.set('kind', payload.kind);

    const response = await api.get<{ step: { raw_request?: unknown; raw_response?: unknown } }>(
      `/api/bff/chat-messages/${payload.messageId}/steps/${payload.stepId}/raw?${params.toString()}`
    );

    return payload.kind === 'request' ? response.step?.raw_request ?? null : response.step?.raw_response ?? null;
  };

  const stepDetailsOpen = ref(false);
  const stepDetailsStep = ref<ChatMessageStep | null>(null);
  const stepDetailsMessageId = ref<number | null>(null);
  const stepDetailsMessageStatus = ref<ChatBranchMessage['status'] | null>(null);
  const stepDetailsShowBilling = ref(false);
  const stepDetailsShowResponse = ref(false);
  const stepDetailsRetryFromStepPending = ref(false);

  const stepDetailsRequestLoading = ref(false);
  const stepDetailsRequestError = ref('');
  const stepDetailsRequestPayload = ref<unknown>(null);
  const stepDetailsRequestToken = ref(0);

  const stepDetailsResponseLoading = ref(false);
  const stepDetailsResponseError = ref('');
  const stepDetailsResponsePayload = ref<unknown>(null);
  const stepDetailsResponseToken = ref(0);

  const loadStepDetailsRaw = async (
    kind: 'request' | 'response',
    payload: { messageId: number; stepId: number }
  ) => {
    const isRequest = kind === 'request';
    const token = (isRequest ? stepDetailsRequestToken : stepDetailsResponseToken).value + 1;

    if (isRequest) {
      stepDetailsRequestToken.value = token;
      stepDetailsRequestLoading.value = true;
      stepDetailsRequestError.value = '';
      stepDetailsRequestPayload.value = null;
    } else {
      stepDetailsResponseToken.value = token;
      stepDetailsResponseLoading.value = true;
      stepDetailsResponseError.value = '';
      stepDetailsResponsePayload.value = null;
    }

    try {
      const rawPayload = await fetchStepRawPayload({
        messageId: payload.messageId,
        stepId: payload.stepId,
        kind,
      });

      if (isRequest) {
        if (stepDetailsRequestToken.value !== token) return;
        stepDetailsRequestPayload.value = rawPayload;
      } else {
        if (stepDetailsResponseToken.value !== token) return;
        stepDetailsResponsePayload.value = rawPayload;
      }
    } catch (error) {
      const errorText =
        error instanceof Error && error.message === 'Step is not available'
          ? error.message
          : 'Failed to load payload';

      if (isRequest) {
        if (stepDetailsRequestToken.value !== token) return;
        stepDetailsRequestError.value = errorText;
      } else {
        if (stepDetailsResponseToken.value !== token) return;
        stepDetailsResponseError.value = errorText;
      }
    } finally {
      if (isRequest) {
        if (stepDetailsRequestToken.value === token) {
          stepDetailsRequestLoading.value = false;
        }
      } else if (stepDetailsResponseToken.value === token) {
        stepDetailsResponseLoading.value = false;
      }
    }
  };

  const openStepDetails = (payload: {
    messageId: number;
    messageStatus: ChatBranchMessage['status'];
    step: ChatMessageStep;
    closed: boolean;
  }) => {
    stepDetailsOpen.value = true;
    stepDetailsStep.value = payload.step;
    stepDetailsMessageId.value = payload.messageId;
    stepDetailsMessageStatus.value = payload.messageStatus;
    stepDetailsShowBilling.value = Boolean(payload.closed);
    stepDetailsShowResponse.value = Boolean(payload.closed);
    stepDetailsRetryFromStepPending.value = false;

    const stepId = Number(payload.step.id || 0);
    void loadStepDetailsRaw('request', { messageId: payload.messageId, stepId });
    if (payload.closed) {
      void loadStepDetailsRaw('response', { messageId: payload.messageId, stepId });
    } else {
      stepDetailsResponseLoading.value = false;
      stepDetailsResponseError.value = '';
      stepDetailsResponsePayload.value = null;
      stepDetailsResponseToken.value += 1;
    }
  };

  const closeStepDetails = () => {
    stepDetailsOpen.value = false;
    stepDetailsStep.value = null;
    stepDetailsMessageId.value = null;
    stepDetailsMessageStatus.value = null;
    stepDetailsShowBilling.value = false;
    stepDetailsShowResponse.value = false;
    stepDetailsRetryFromStepPending.value = false;
    stepDetailsRequestLoading.value = false;
    stepDetailsRequestError.value = '';
    stepDetailsRequestPayload.value = null;
    stepDetailsRequestToken.value += 1;
    stepDetailsResponseLoading.value = false;
    stepDetailsResponseError.value = '';
    stepDetailsResponsePayload.value = null;
    stepDetailsResponseToken.value += 1;
  };

  const retryFromStep = async () => {
    const messageId = stepDetailsMessageId.value;
    const step = stepDetailsStep.value;
    const stepId = Number(step?.id || 0);

    if (!messageId || !stepId) return;
    if (stepDetailsRetryFromStepPending.value) return;

    if (stepDetailsMessageStatus.value === 'generating') {
      alert('Retry from this step is available after generation stops.');
      return;
    }

    const stepNumber =
      typeof step?.sequence === 'number' && Number.isFinite(step.sequence) && step.sequence > 0
        ? step.sequence
        : '—';

    const ok = confirm(
      `Retry from step ${stepNumber}? This will delete this step and all following steps for this message.`
    );

    if (!ok) return;

    stepDetailsRetryFromStepPending.value = true;
    loadError.value = '';

    try {
      const payload = await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
        `/api/bff/chat-messages/${messageId}/steps/${stepId}/retry-from-step`,
        {}
      );

      branch.value = payload.branch || [];

      const generationId = payload.generation?.message_id;
      closeStepDetails();

      if (generationId) {
        await startPolling(generationId);
      }

      void scrollToLastMessage({ behavior: 'smooth', block: 'end' });
    } catch (error) {
      console.error(error);
      alert(errorMessage(error, 'Failed to retry from this step.'));
    } finally {
      stepDetailsRetryFromStepPending.value = false;
    }
  };

  const contentFullOpen = ref(false);
  const contentFullTitle = ref('Tool result');
  const contentFullLoading = ref(false);
  const contentFullError = ref('');
  const contentFullText = ref('');
  const contentFullRequestToken = ref(0);

  const openContentFull = async (payload: {
    messageId: number;
    contentId: number;
    title?: string;
  }) => {
    contentFullOpen.value = true;
    contentFullTitle.value = payload.title || 'Tool result';
    contentFullLoading.value = true;
    contentFullError.value = '';
    contentFullText.value = '';

    const token = contentFullRequestToken.value + 1;
    contentFullRequestToken.value = token;

    try {
      if (!payload.contentId || payload.contentId <= 0) {
        throw new Error('Content is not available');
      }

      const response = await api.get<{ content: { content_text?: string | null } }>(
        `/api/bff/chat-messages/${payload.messageId}/contents/${payload.contentId}/full`
      );

      if (contentFullRequestToken.value !== token) return;
      contentFullText.value = String(response.content?.content_text ?? '');
    } catch (error) {
      if (contentFullRequestToken.value !== token) return;
      contentFullError.value =
        error instanceof Error && error.message === 'Content is not available'
          ? error.message
          : 'Failed to load content';
    } finally {
      if (contentFullRequestToken.value === token) {
        contentFullLoading.value = false;
      }
    }
  };

  const closeContentFull = () => {
    contentFullOpen.value = false;
    contentFullTitle.value = 'Tool result';
    contentFullLoading.value = false;
    contentFullError.value = '';
    contentFullText.value = '';
    contentFullRequestToken.value += 1;
  };

  const attachmentPreviewOpen = ref(false);
  const attachmentPreviewTitle = ref('Attachment');
  const attachmentPreviewUrl = ref('');
  const attachmentPreviewKind = ref<'image' | 'text' | 'markdown' | 'binary'>('binary');
  const attachmentPreviewLoading = ref(false);
  const attachmentPreviewError = ref('');
  const attachmentPreviewText = ref('');
  const attachmentPreviewRequestToken = ref(0);

  const openAttachmentPreview = async (payload: {
    messageId: number;
    content: ChatMessageContent;
  }) => {
    const messageId = Number(payload.messageId || 0);
    const contentId = Number(payload.content?.id || 0);
    const name = getAttachmentName(payload.content);
    const mimeType = getAttachmentMimeType(payload.content);
    const isImage = Boolean(payload.content.media?.is_image);

    if (!messageId || !contentId) return;

    attachmentPreviewOpen.value = true;
    attachmentPreviewTitle.value = name;
    attachmentPreviewUrl.value = buildMessageContentFileUrl(messageId, contentId);
    attachmentPreviewKind.value = getAttachmentPreviewKind(name, mimeType, isImage);
    attachmentPreviewLoading.value = attachmentPreviewKind.value !== 'image';
    attachmentPreviewError.value = '';
    attachmentPreviewText.value = '';

    const token = attachmentPreviewRequestToken.value + 1;
    attachmentPreviewRequestToken.value = token;

    if (attachmentPreviewKind.value === 'image' || attachmentPreviewKind.value === 'binary') {
      attachmentPreviewLoading.value = false;
      return;
    }

    try {
      const response = await fetch(attachmentPreviewUrl.value);
      if (!response.ok) throw new Error(`Failed to load attachment (${response.status})`);
      const text = await response.text();
      if (attachmentPreviewRequestToken.value !== token) return;
      attachmentPreviewText.value = text;
    } catch (error) {
      if (attachmentPreviewRequestToken.value !== token) return;
      attachmentPreviewError.value = error instanceof Error ? error.message : 'Failed to load attachment';
    } finally {
      if (attachmentPreviewRequestToken.value === token) {
        attachmentPreviewLoading.value = false;
      }
    }
  };

  const closeAttachmentPreview = () => {
    attachmentPreviewOpen.value = false;
    attachmentPreviewTitle.value = 'Attachment';
    attachmentPreviewUrl.value = '';
    attachmentPreviewKind.value = 'binary';
    attachmentPreviewLoading.value = false;
    attachmentPreviewError.value = '';
    attachmentPreviewText.value = '';
    attachmentPreviewRequestToken.value += 1;
  };

  const botModalOpen = ref(false);
  const botModalValue = ref<number | ''>('');
  const savingBot = ref(false);

  const openBotModal = () => {
    botModalValue.value = chat.value?.bot_id ?? '';
    botModalOpen.value = true;
  };

  const closeBotModal = () => {
    botModalOpen.value = false;
  };

  const saveBotSelection = async () => {
    if (!chatId.value || savingBot.value) return;
    savingBot.value = true;
    try {
      const botId = botModalValue.value === '' ? null : Number(botModalValue.value);
      await api.patch(`/api/bff/chats/${chatId.value}`, { bot_id: botId });
      await loadChat({ mode: 'soft' });
      closeBotModal();
    } catch (error) {
      console.error(error);
      alert('Failed to update bot.');
    } finally {
      savingBot.value = false;
    }
  };

  const updateConfig = async () => {
    if (!chatId.value) return;
    if (activeGenerationId.value) {
      alert('Cannot change configuration while generating a response.');
      selectedConfig.value = appliedConfig.value;
      return;
    }
    if (isConfigSyncPending.value) return;

    const token = (configSyncToken += 1);
    configSyncStatus.value = 'pending';
    configSyncError.value = '';

    const cfgId = selectedConfig.value === '' ? null : Number(selectedConfig.value);

    try {
      const payload = await api.patch<{ chat: Chat }>(`/api/bff/chats/${chatId.value}`, {
        llm_configuration_id: cfgId,
      });

      if (configSyncToken !== token) return;
      chat.value = payload.chat;
      selectedConfig.value = payload.chat?.llm_configuration_id ?? '';
      await refreshPromptContextFromServer();
      configSyncStatus.value = 'synced';
    } catch (error) {
      console.error(error);
      if (configSyncToken !== token) return;
      selectedConfig.value = appliedConfig.value;
      configSyncStatus.value = 'error';
      configSyncError.value = 'Failed to switch configuration. Check your connection and try again.';
    }
  };

  const openConfigEditor = () => {
    if (!selectedConfig.value) return;
    stackNav.open({
      path: `/catalogs/llm-configurations/${selectedConfig.value}`,
      query: { returnTo: route.fullPath },
    });
    closeMenu();
  };

  const openBotEditor = () => {
    if (!currentBotId.value) return;
    stackNav.open({ path: `/catalogs/bots/${currentBotId.value}`, query: { returnTo: route.fullPath } });
    closeMenu();
  };

  const openBotTools = () => {
    alert('Not implemented yet.');
    closeMenu();
  };

  const dismissMissingToolsBanner = () => {
    showMissingToolsBanner.value = false;
  };

  const duplicateActiveBranch = async () => {
    alert('Not implemented yet.');
  };

  const exportMarkdown = async () => {
    alert('Not implemented yet.');
  };

  const exportYaml = async () => {
    alert('Not implemented yet.');
  };

  const removeChat = async () => {
    if (!chatId.value || ui.deleting.value) return;
    const ok = confirm('Delete this chat? All messages will be removed.');
    if (!ok) {
      closeMenu();
      return;
    }
    ui.deleting.value = true;
    try {
      await api.del(`/api/bff/chats/${chatId.value}`);
      closeMenu();
      await router.push('/');
    } finally {
      ui.deleting.value = false;
    }
  };

  const openContextBlockEditor = (blockId: number) => {
    const ids = Array.from(
      new Set((linkedBlocks.value || []).map((item) => item.block?.id).filter((id): id is number => typeof id === 'number'))
    );
    const navKey = createRecordset(ids, { returnTo: route.fullPath });
    stackNav.open({ path: `/catalogs/knowledge-blocks/${blockId}`, query: { navKey, returnTo: route.fullPath } });
  };

  const chatBlocksOriginal = ref<ChatBlockLink[]>([]);
  const chatBlocksDraft = ref<ChatBlockLink[]>([]);
  let tempChatBlockId = -1;

  const toChatBlockLinks = (bindings: ChatKnowledgeBlock[]) =>
    (bindings || []).map((b) => ({
      id: b.id,
      block: b.knowledge_block_id,
      enabled: Boolean(b.enabled),
      sequence: Number(b.sequence) || 0,
    }));

  const normalizeSequences = (items: ChatBlockLink[]) => {
    return [...items].map((item, idx) => ({ ...item, sequence: idx }));
  };

  const chatBlocks = computed(() => chatBlocksDraft.value);

  const chatVariablesOriginal = ref<Partial<ChatVariable>[]>([]);
  const chatVariables = ref<Partial<ChatVariable>[]>([]);

  const chatTabDirty = computed(() => {
    const varsA = normalizeVariablesForCompare(chatVariablesOriginal.value);
    const varsB = normalizeVariablesForCompare(chatVariables.value);
    const blocksA = normalizeChatBlocksForCompare(chatBlocksOriginal.value);
    const blocksB = normalizeChatBlocksForCompare(chatBlocksDraft.value);
    return jsonStable(varsA) !== jsonStable(varsB) || jsonStable(blocksA) !== jsonStable(blocksB);
  });

  const savingChatChanges = ref(false);

  const cancelChatChanges = () => {
    chatVariables.value = [...chatVariablesOriginal.value];
    chatBlocksDraft.value = [...chatBlocksOriginal.value];
  };

  const saveChatChanges = async () => {
    if (!chatId.value || savingChatChanges.value) return;
    savingChatChanges.value = true;
    try {
      await api.patch(`/api/bff/chats/${chatId.value}`, {
        variables: chatVariables.value,
        knowledge_block_bindings: (chatBlocksDraft.value || []).map((b) => ({
          ...(b.id > 0 ? { id: b.id } : {}),
          knowledge_block_id: b.block,
          enabled: Boolean(b.enabled),
        })),
      });

      await loadChat({ mode: 'soft' });
    } catch (error) {
      console.error(error);
      alert('Failed to save chat changes.');
    } finally {
      savingChatChanges.value = false;
    }
  };

  const touchChatBlocks = () => {
    // Mutations happen via v-model; this hook exists for parity with v1.
  };

  const openChatBlocksPicker = () => {
    chatBlocksPickerSelection.value = [];
    chatBlocksPickerOpen.value = true;
  };

  const openChatBlockEditor = (blockId: number) => {
    const ids = Array.from(
      new Set((chatBlocks.value || []).map((b) => b.block).filter((id): id is number => typeof id === 'number' && id > 0))
    );
    const navKey = createRecordset(ids, { returnTo: route.fullPath });
    stackNav.open({ path: `/catalogs/knowledge-blocks/${blockId}`, query: { navKey, returnTo: route.fullPath } });
  };

  const moveChatBlock = (binding: ChatBlockLink, delta: number) => {
    const idx = chatBlocksDraft.value.findIndex((b) => b.id === binding.id);
    if (idx === -1) return;
    const nextIndex = idx + delta;
    if (nextIndex < 0 || nextIndex >= chatBlocksDraft.value.length) return;
    const next = [...chatBlocksDraft.value];
    const tmp = next[idx];
    next[idx] = next[nextIndex];
    next[nextIndex] = tmp;
    chatBlocksDraft.value = normalizeSequences(next);
  };

  const removeChatBlock = (bindingId: number) => {
    chatBlocksDraft.value = chatBlocksDraft.value.filter((b) => b.id !== bindingId);
  };

  const chatBlockName = (blockId: number) => {
    const block = (knowledgeBlocks.value || []).find((b) => b.id === blockId);
    return block?.name || `Block #${blockId}`;
  };

  const chatBlockImage = (blockId: number) => {
    const block = (knowledgeBlocks.value || []).find((b) => b.id === blockId);
    return block?.image || null;
  };

  const chatBlockMeta = (binding: ChatBlockLink) => {
    const block = (knowledgeBlocks.value || []).find((b) => b.id === binding.block);
    const type = block?.type || 'Block';
    const tokens = block?.token_count ?? 0;
    return `${type} · ${tokens} tokens`;
  };

  const addVariableRow = () => {
    chatVariables.value = [...chatVariables.value, { key: '', value: '' }];
  };

  const chatBlocksPickerOpen = ref(false);
  const chatBlocksPickerSelection = ref<number[]>([]);
  const linkedChatBlockIds = computed(() => chatBlocksDraft.value.map((b) => b.block));

  const addChatBlocks = (blockIds: number[]) => {
    const existing = new Set(linkedChatBlockIds.value);
    const additions = (blockIds || []).filter((id) => !existing.has(id));
    if (!additions.length) return;

    const base = normalizeSequences(chatBlocksDraft.value);
    const next = [...base];
    let seq = next.length;
    for (const id of additions) {
      seq += 1;
      next.push({ id: tempChatBlockId--, block: id, enabled: true, sequence: seq });
    }
    chatBlocksDraft.value = normalizeSequences(next);
  };

  const loadKnowledgeBlocksCatalog = async () => {
    try {
      const qs = new URLSearchParams();
      qs.set('sort', 'name');
      qs.set('fields[knowledge-blocks]', 'name,version,type,token_count,image');
      const payload = await jsonApiList('/api/ash/knowledge-blocks', qs);
      knowledgeBlocks.value = (payload.data || [])
        .map((resource) => {
          const id = toIntId(resource.id);
          if (!id) return null;
          const attrs = (resource.attributes || {}) as Record<string, unknown>;
          return {
            id,
            name: String(attrs.name || ''),
            image: parseImageAsset(attrs.image),
            type: typeof attrs.type === 'string' ? attrs.type : null,
            version: typeof attrs.version === 'string' ? attrs.version : null,
            token_count: typeof attrs.token_count === 'number' ? attrs.token_count : toIntId(attrs.token_count as any),
          } satisfies KnowledgeBlock;
        })
        .filter((block): block is KnowledgeBlock => Boolean(block));
    } catch (error) {
      console.warn('Failed to load knowledge blocks', error);
    }
  };

  const newBlockDraft = useKnowledgeBlockNewDraft({
    linkedBlockIds: () => linkedChatBlockIds.value,
    onBlocksCreated: async (createdIds) => {
      await loadKnowledgeBlocksCatalog();
      addChatBlocks(createdIds);
    },
    resetOn: () => chatId.value,
  });

  const openNewBlock = newBlockDraft.openNewBlock;

  const loadChat = async (opts: { mode?: 'initial' | 'soft' } = {}) => {
    const mode = opts.mode || 'initial';
    if (mode === 'initial') {
      loaded.value = false;
    }
    loadError.value = '';
    if (mode === 'initial') {
      stopPolling();
      activeGenerationId.value = null;
    }

    const payload = await api.get<ChatStatePayload>(`/api/bff/chats/${chatId.value}/state`);

    chat.value = payload.chat;
    chatNote.value = payload.chat?.note || '';
    branch.value = payload.branch || [];
    counters.value = payload.counters || counters.value;
    promptSources.value = payload.prompt_sources || promptSources.value;
    compiledPromptText.value = payload.compiled_prompt_text || '';

    bots.value = payload.options?.bots || [];
    llmConfigurations.value = payload.options?.llm_configurations || [];
    knowledgeBlocks.value = payload.options?.knowledge_blocks || [];

    selectedConfig.value = payload.chat?.llm_configuration_id ?? '';
    configSyncStatus.value = 'synced';
    configSyncError.value = '';

    chatBlocksOriginal.value = normalizeSequences(toChatBlockLinks(payload.chat_blocks || []));
    chatBlocksDraft.value = [...chatBlocksOriginal.value];

    chatVariablesOriginal.value = payload.chat?.variables || [];
    chatVariables.value = [...chatVariablesOriginal.value];

    void loadBotToolsState(payload.chat?.bot_id ?? null);

    const generating = payload.active_generation_message_id || null;
    if (generating) {
      if (activeGenerationId.value !== generating) {
        void startPolling(generating);
      }
    } else if (activeGenerationId.value != null) {
      activeGenerationId.value = null;
      cancelingGenerationId.value = null;
      stopPolling();
    }

    loaded.value = true;
    if (mode === 'initial') {
      if (!hasFocusMessageQuery()) {
        void scrollToLastMessage();
      }
    }
  };

  const loadChatSafe = async (opts: { mode?: 'initial' | 'soft' } = {}) => {
    try {
      await loadChat(opts);
    } catch (error) {
      console.error(error);
      loadError.value = error instanceof Error ? error.message : 'Failed to load chat.';
    } finally {
      loaded.value = true;
    }
  };

  watch(
    () => chatId.value,
    () => {
      if (!chatId.value) return;
      clearBranchSearchTimer();
      branchSearchTerm.value = '';
      resetBranchSearch();
      void (async () => {
        await loadChatSafe();
        await handleFocusMessage();
      })();
    }
  );

  watch(
    () => stack.active.value,
    (active, wasActive) => {
      if (!chatId.value) return;
      if (active) return;
      if (wasActive !== true) return;
      void (async () => {
        const handled = await newBlockDraft.consumePendingNewBlockContext();
        if (handled) return;
        await loadChatSafe({ mode: 'soft' });
      })();
    }
  );

  const handleKeyNavigation = (event: KeyboardEvent) => {
    if (event.key === 'Escape') {
      if (menuOpen.value) closeMenu();
      if (isMobile.value && (leftOpen.value || rightOpen.value)) closeOverlays();
    }
  };

  onMounted(() => {
    ui.restorePanelState();
    ui.mountListeners(handleKeyNavigation);
    document.addEventListener('visibilitychange', handleVisibilityChange);
    window.addEventListener('pageshow', handlePageShow);
    window.addEventListener('focus', handleFocus);
    if (chatId.value) {
      void (async () => {
        await loadChatSafe();
        await handleFocusMessage();
      })();
    }
  });

  onBeforeUnmount(() => {
    stopPolling();
    clearBranchSearchTimer();
    document.removeEventListener('visibilitychange', handleVisibilityChange);
    window.removeEventListener('pageshow', handlePageShow);
    window.removeEventListener('focus', handleFocus);
    ui.unmountListeners();
  });

  return {
    loaded,
    loadError,
    chat,
    chatNote,
    branch,
    counters,
    bots,
    llmConfigurations,
    knowledgeBlocks,
    selectableConfigs,
    selectedConfig,
    appliedConfig,
    configSyncStatus,
    configSyncError,
    isConfigSyncPending,
    selectedDisabledConfig,
    selectedDisabledConfigReason,
    configLabel,
    editConfigLabel,
    menuOpen,
    menuStyle,
    currentBotId,
    currentBotName,
    canAttachFiles,
    fileInputAccept,
    fileAttachTitle,
    fileDropHint,
    showMissingToolsBanner,
    missingRequiredPerUserToolAliases,
    leftOpen,
    rightOpen,
    leftTab,
    isMobile,
    gridColumns,
    toggleMenu,
    setMenuRef,
    setMenuAnchorRef,
    setMenuButtonRef,
    openConfigEditor,
    openBotEditor,
    openBotTools,
    dismissMissingToolsBanner,
    closeOverlays,
    promptTokenCount,
    historyTokenCount,
    totalTokenCount,
    showContextUsageIndicator,
    contextUsagePercentRounded,
    contextUsageTitle,
    isContextSoftLimitReached,
    contextUsagePercent,
    isAgentHistoryMode,
    agentContextTokenCount,
    branchSearchTerm,
    hasBranchSearch,
    branchSearchLoading,
    branchSearchError,
    branchSearchResults,
    linkedBlocks,
    SOURCE_LABELS,
    botToolsLoading,
    botToolsError,
    activeToolInstances,
    formatStepMetric,
    searchHitMeta,
    messageMetaLabel,
    messagePrimaryText,
    preview,
    hasBlockVersion,
    formatBlockVersion,
    handleBranchItemClick,
    handleSearchResultClick,
    switchBranchHandler,
    openContextBlockEditor,
    chatWindowRef,
    setMessageRef,
    copiedMessageId,
    retryingMessageId,
    branchingAssistantId,
    isWorkingOpen,
    toggleWorking,
    canDeleteMessage,
    deleteMessageTitle,
    copyMessage,
    startEdit,
    startBranch,
    retryLastStep,
    confirmAndDeleteMessage,
    draft,
    pendingFiles,
    addPendingFiles,
    onPendingFilesSelected,
    removePendingFile,
    sending,
    activeGenerationId,
    cancelingGenerationId,
    handleCancelPointerDown,
    send,
    cancelActiveGeneration,
    editingMessage,
    modalMode,
    editContents,
    editExistingAttachments,
    editPendingFiles,
    editError,
    editAttachmentHelp: fileAttachTitle,
    savingEdit,
    cancelEdit,
    addEditPendingFiles,
    removeEditPendingFile,
    removeEditExistingAttachment,
    saveEdit,
    promptModalOpen,
    promptLoading,
    promptError,
    promptText,
    openPromptModal,
    closePromptModal,
    noteModalOpen,
    noteModalValue,
    savingNote,
    openNoteModal,
    closeNoteModal,
    saveNote,
    stepDetailsOpen,
    stepDetailsStep,
    stepDetailsMessageId,
    stepDetailsMessageStatus,
    stepDetailsShowBilling,
    stepDetailsShowResponse,
    stepDetailsRetryFromStepPending,
    stepDetailsRequestLoading,
    stepDetailsRequestError,
    stepDetailsRequestPayload,
    stepDetailsResponseLoading,
    stepDetailsResponseError,
    stepDetailsResponsePayload,
    openStepDetails,
    closeStepDetails,
    retryFromStep,
    contentFullOpen,
    contentFullTitle,
    contentFullLoading,
    contentFullError,
    contentFullText,
    openContentFull,
    closeContentFull,
    attachmentPreviewOpen,
    attachmentPreviewTitle,
    attachmentPreviewUrl,
    attachmentPreviewKind,
    attachmentPreviewLoading,
    attachmentPreviewError,
    attachmentPreviewText,
    openAttachmentPreview,
    closeAttachmentPreview,
    botModalOpen,
    botModalValue,
    savingBot,
    openBotModal,
    closeBotModal,
    saveBotSelection,
    duplicating: ui.duplicating,
    exporting: ui.exporting,
    deleting: ui.deleting,
    duplicateActiveBranch,
    exportMarkdown,
    exportYaml,
    removeChat,
    chatTabDirty,
    savingChatChanges,
    chatBlocks,
    chatVariables,
    chatBlockName,
    chatBlockImage,
    chatBlockMeta,
    saveChatChanges,
    cancelChatChanges,
    openChatBlocksPicker,
    openNewBlock,
    openChatBlockEditor,
    moveChatBlock,
    removeChatBlock,
    touchChatBlocks,
    addVariableRow,
    chatBlocksPickerOpen,
    chatBlocksPickerSelection,
    linkedChatBlockIds,
    addChatBlocks,
    compiledPromptText,
    updateConfig,
  };
}

const buildSendFormData = async (
  content: string,
  files: PendingChatFile[],
  existingAttachments: ExistingChatAttachment[] = [],
  parentId?: number | null
) => {
  const form = new FormData();
  form.append('content', content);
  if (parentId === null) {
    form.append('parent_id', '');
  } else if (typeof parentId === 'number') {
    form.append('parent_id', String(parentId));
  }

  const existingFiles = await Promise.all(existingAttachments.map(cloneExistingAttachmentFile));
  for (const file of existingFiles) {
    form.append('files', file, file.name);
  }

  for (const item of files) {
    form.append('files', item.file, item.name);
  }
  return form;
};

const buildMessageUpdateFormData = (
  contents: Array<{ id: number; content_text: string }> | null,
  removeContentIds: number[],
  files: PendingChatFile[]
) => {
  const form = new FormData();
  if (contents && contents.length > 0) {
    form.append('contents_json', JSON.stringify(contents));
  }

  if (removeContentIds.length > 0) {
    form.append('remove_content_ids_json', JSON.stringify(removeContentIds));
  }

  for (const item of files) {
    form.append('files', item.file, item.name);
  }

  return form;
};

const cloneExistingAttachmentFile = async (attachment: ExistingChatAttachment) => {
  const response = await fetch(buildMessageContentFileUrl(attachment.messageId, attachment.id));
  if (!response.ok) {
    throw new Error(`Failed to load attachment ${JSON.stringify(attachment.name)}.`);
  }

  const blob = await response.blob();
  const type = blob.type || attachment.mimeType || 'application/octet-stream';
  return new File([blob], attachment.name, { type });
};
