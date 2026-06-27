import { computed, onBeforeUnmount, onMounted, ref, watch, type ComponentPublicInstance } from 'vue';
import { useRoute, useRouter } from 'vue-router';

import { api, getApiErrorMessage, isHttpError } from '@/api/client';
import { continueChatRecord } from '@/features/chat/chatAshApi';
import { useChatContextPanel } from '@/features/chat/model/useChatContextPanel';
import { useChatComposerRuntime } from '@/features/chat/model/useChatComposerRuntime';
import { useChatHeaderControls } from '@/features/chat/model/useChatHeaderControls';
import { useChatInspectors } from '@/features/chat/model/useChatInspectors';
import { useChatLibraryDraft } from '@/features/chat/model/useChatLibraryDraft';
import { useChatMessageActions } from '@/features/chat/model/useChatMessageActions';
import {
  useChatUiChrome,
} from '@/features/chat/model/useChatUiChrome';
import {
  type ChatIdleStatePayload,
  type ChatPromptContextPayload,
  type ChatSettingsStatePayload,
  type ChatStatePayload,
  type Counters,
} from '@/features/chat/model/chatViewModel.shared';
import { SOURCE_LABELS } from '@/features/chat/types';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { useStackLayer } from '@/features/stack/useStackLayer';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import { usePageTitleOverride } from '@/features/app/documentTitle';
import type {
  Bot,
  Chat,
  ChatBranchMessage,
  ChatRelationSummary,
  ChatRelations,
  Group,
  KnowledgeBlock,
  LlmConfiguration,
  ToolInstanceOption,
} from '@/types/api';

type ChatShareEligibility = {
  id: number;
  eligible: boolean;
  disabled_reason?: string | null;
};

type ChatShareState = {
  group_ids?: number[];
  eligible_group_ids?: number[];
  group_eligibility?: ChatShareEligibility[];
};

const CHAT_IDLE_POLL_DELAY_MS = 30_000;
const CHAT_IDLE_POLL_RETRY_DELAY_MS = 30_000;
const CHAT_IDLE_IMMEDIATE_THROTTLE_MS = 1_500;

function getQueryString(value: unknown) {
  if (Array.isArray(value)) {
    const firstString = value.find((item) => typeof item === 'string');
    return firstString || '';
  }
  return typeof value === 'string' ? value : '';
}

function readChatListReturnTarget(value: unknown) {
  const raw = getQueryString(value).trim();
  if (
    raw === '/' ||
    raw === '/chats' ||
    raw.startsWith('/?') ||
    raw.startsWith('/#') ||
    raw.startsWith('/chats?') ||
    raw.startsWith('/chats#')
  ) {
    return raw;
  }
  return '/chats';
}

const emptyChatRelations = (): ChatRelations => ({
  parent: null,
  children_by_message_id: {},
  children_without_message: [],
});

export function useChatViewModel() {
  const route = useRoute();
  const router = useRouter();
  const stackNav = useStackNavigation();
  const stack = useNavigationStack();
  const layer = useStackLayer();
  const chatId = computed(() => Number(route.params.id));
  const chatsReturnTarget = computed(() => readChatListReturnTarget(route.query.returnTo));
  const chatRouteTarget = (id: number, query: Record<string, string> = {}) => ({
    path: `/chats/${id}`,
    query,
  });

  const navigateToChat = (id: number, query: Record<string, string> = {}) => {
    const target = chatRouteTarget(id, query);
    if (stack.active.value) return stackNav.replace(target);
    return router.push(target);
  };

  const navigateToChatPath = (path: string, query: Record<string, string> = {}) => {
    const target = Object.keys(query).length ? { path, query } : { path };
    if (stack.active.value) return stackNav.replace(target);
    return router.push(target);
  };

  const goToChats = () => {
    if (stack.active.value) return stackNav.close();
    return router.push(chatsReturnTarget.value);
  };

  const ui = useChatUiChrome();

  const loaded = ref(false);
  const loadError = ref('');
  const chatUnavailable = ref(false);

  const chat = ref<Chat | null>(null);
  const chatNote = ref('');
  const canEdit = computed(() => chat.value?.can_edit !== false);
  const sharedReadonly = computed(() => chat.value?.can_edit === false && chat.value?.shared_incoming === true);
  const branch = ref<ChatBranchMessage[]>([]);
  const relations = ref<ChatRelations>(emptyChatRelations());
  const counters = ref<Counters>({
    prompt_token_count: 0,
    history_token_count: 0,
    history_message_count: 0,
  });

  const promptSources = ref<ChatSettingsStatePayload['prompt_sources']>({
    bot: [],
    chat: [],
    configuration: [],
    user: [],
  });
  const promptBlocks = ref<ChatSettingsStatePayload['prompt_blocks']>([]);
  const compiledPromptText = ref('');

  const bots = ref<Bot[]>([]);
  const noBotSortActivityAt = ref<string | null>(null);
  const chatBlockCount = ref(0);
  const chatToolCount = ref(0);
  const llmConfigurations = ref<LlmConfiguration[]>([]);
  const knowledgeBlocks = ref<KnowledgeBlock[]>([]);
  const toolLibrary = ref<ToolInstanceOption[]>([]);
  const artifactToolsAvailable = ref(false);

  const activeGenerationId = ref<number | null>(null);
  const cancelingGenerationId = ref<number | null>(null);
  const chatIdleRevision = ref<string | null>(null);
  const continuingConversation = ref(false);
  const handoffPending = ref(false);
  const parentRelation = computed(() => relations.value.parent || null);
  const fallbackChildRelations = computed(() => relations.value.children_without_message || []);
  const childRelationsForMessage = (messageId?: number | null): ChatRelationSummary[] => {
    if (!messageId) return [];
    return relations.value.children_by_message_id?.[String(messageId)] || [];
  };

  const shareModalOpen = ref(false);
  const shareGroups = ref<Group[]>([]);
  const sharedGroupIds = ref<number[]>([]);
  const shareDisabledGroupIds = ref<number[]>([]);
  const shareDisabledGroupReasons = ref<Record<number, string>>({});
  const shareLoading = ref(false);
  const shareSaving = ref(false);

  type TemplateRefValue = Element | ComponentPublicInstance | null;

  const toHTMLElement = (el: TemplateRefValue) => (el instanceof HTMLElement ? el : null);

  const setMenuRef = (el: TemplateRefValue) => {
    ui.menuRef.value = toHTMLElement(el);
  };

  const setMenuAnchorRef = (el: TemplateRefValue) => {
    ui.menuAnchorRef.value = toHTMLElement(el);
  };

  const setMenuButtonRef = (el: TemplateRefValue) => {
    ui.menuButtonRef.value = toHTMLElement(el);
  };

  const refreshPromptContextFromServer = async () => {
    if (!chatId.value) return;
    const payload = await api.get<ChatPromptContextPayload>(`/api/bff/chat-state/${chatId.value}/prompt-context`);
    promptSources.value = payload.prompt_sources || promptSources.value;
    promptBlocks.value = payload.prompt_blocks || [];
    compiledPromptText.value = payload.compiled_prompt_text || '';
    counters.value = payload.counters || counters.value;
  };

  const headerControls = useChatHeaderControls({
    chatId,
    routeFullPath: () => route.fullPath,
    chat,
    chatNote,
    canEdit,
    bots,
    noBotSortActivityAt,
    chatBlockCount,
    chatToolCount,
    llmConfigurations,
    artifactToolsAvailable,
    activeGenerationId,
    menuOpen: ui.menuOpen,
    deleting: ui.deleting,
    toggleMenu: ui.toggleMenu,
    closeMenu: ui.closeMenu,
    stackOpen: stackNav.open,
    pushRoute: async (path, query = {}) => {
      if (path === '/') {
        await goToChats();
        return;
      }
      if (path.startsWith('/chats/')) {
        await navigateToChatPath(path, query);
        return;
      }
      await (Object.keys(query).length ? router.push({ path, query }) : router.push(path));
    },
    reloadChat: () => loadChat({ mode: 'soft' }),
    refreshPromptContext: () => refreshPromptContextFromServer(),
  });
  const handoffDisabled = computed(
    () =>
      !canEdit.value ||
      Boolean(activeGenerationId.value) ||
      headerControls.isConfigSyncPending.value ||
      handoffPending.value
  );
  const chatDocumentTitle = computed(() => {
    if (!chat.value || chatUnavailable.value) return 'Chat';
    return headerControls.chatFullTitle.value || 'Chat';
  });

  usePageTitleOverride(chatDocumentTitle);

  const contextPanel = useChatContextPanel({
    chatId,
    branch,
    readOnly: sharedReadonly,
    promptSources,
    promptBlocks,
    currentConfig: headerControls.currentConfig,
    currentBotInfo: headerControls.currentBotInfo,
    isMobile: ui.isMobile,
    leftOpen: ui.leftOpen,
    messageConfigLabel: headerControls.messageConfigLabel,
    routeFullPath: () => route.fullPath,
    routeQuery: () => route.query as Record<string, unknown>,
    replaceRouteQuery: async (query) => {
      await router.replace({ path: route.path, query });
    },
    stackOpen: stackNav.open,
  });
  const scrollToLastMessageIfLayerActive: typeof contextPanel.scrollToLastMessage = async (opts) => {
    if (!layer.active.value) return;
    await contextPanel.scrollToLastMessage(opts);
  };

  let getOpenWorkingPollRequest: (messageId: number) => string | null = () => null;
  let applyWorkingPoll: Parameters<typeof useChatComposerRuntime>[0]['applyWorkingPoll'] = () => {};

  const composerRuntime = useChatComposerRuntime({
    chatId,
    branch,
    readOnly: sharedReadonly,
    loadError,
    fileUploadPolicy: headerControls.fileUploadPolicy,
    waitForConfigSync: headerControls.waitForConfigSync,
    activeGenerationId,
    cancelingGenerationId,
    draftReady: computed(() => loaded.value && Boolean(chat.value)),
    autoScrollEnabled: computed(() => layer.active.value),
    scrollToLastMessage: scrollToLastMessageIfLayerActive,
    getOpenWorkingPollRequest: (messageId) => getOpenWorkingPollRequest(messageId),
    applyWorkingPoll: (messageId, payload) => applyWorkingPoll?.(messageId, payload),
    onGenerationSettled: async () => {
      await loadChatSafe({ mode: 'soft', includeSettings: false });
    },
  });

  const messageActions = useChatMessageActions({
    chatId,
    chat,
    readOnly: sharedReadonly,
    branch,
    selectedConfig: headerControls.selectedConfig,
    fileUploadPolicy: headerControls.fileUploadPolicy,
    waitForConfigSync: headerControls.waitForConfigSync,
    messageConfigLabel: headerControls.messageConfigLabel,
    startPolling: composerRuntime.startPolling,
    scrollToLastMessage: scrollToLastMessageIfLayerActive,
    ensurePendingFilesUploaded: composerRuntime.ensurePendingFilesUploaded,
    removePendingFileFromCollection: composerRuntime.removePendingFileFromCollection,
    clearPendingFilesCollection: composerRuntime.clearPendingFilesCollection,
    pushChatRoute: async (id) => {
      await navigateToChat(id);
    },
    afterBranchSwitched: contextPanel.rerunBranchSearch,
  });

  getOpenWorkingPollRequest = messageActions.getOpenWorkingPollRequest;
  applyWorkingPoll = messageActions.applyWorkingPoll;

  const inspectors = useChatInspectors({
    compiledPromptText,
    loadError,
    replaceBranch: messageActions.replaceBranch,
    branchMessageById: messageActions.branchMessageById,
    retryConfigurationWarning: messageActions.retryConfigurationWarning,
    startPolling: composerRuntime.startPolling,
    scrollToLastMessage: scrollToLastMessageIfLayerActive,
    composerPendingFiles: composerRuntime.pendingFiles,
    editPendingFiles: messageActions.editPendingFiles,
    editExistingAttachments: messageActions.editExistingAttachments,
  });

  const libraryDraft = useChatLibraryDraft({
    chatId,
    readOnly: sharedReadonly,
    knowledgeBlocks,
    toolLibrary,
    routeFullPath: () => route.fullPath,
    stackOpen: stackNav.open,
    reloadChat: () => loadChat({ mode: 'soft' }),
  });

  const applySettingsState = (payload: ChatSettingsStatePayload) => {
    counters.value = payload.counters || counters.value;
    promptSources.value = payload.prompt_sources || promptSources.value;
    promptBlocks.value = payload.prompt_blocks || [];
    compiledPromptText.value = payload.compiled_prompt_text || '';

    bots.value = payload.options?.bots || [];
    noBotSortActivityAt.value = payload.options?.no_bot_last_activity_at ?? null;
    llmConfigurations.value = payload.options?.llm_configurations || [];
    knowledgeBlocks.value = payload.options?.knowledge_blocks || [];
    toolLibrary.value = payload.options?.tool_instances || [];
    artifactToolsAvailable.value = payload.artifact_tools_available === true;
    const chatBlocks = payload.chat_blocks || [];
    const chatToolBindings = payload.chat_tool_bindings || [];
    chatBlockCount.value = chatBlocks.length;
    chatToolCount.value = chatToolBindings.length;

    headerControls.hydrate({
      selectedConfig: chat.value?.llm_configuration_id ?? '',
      missingRequiredPerUserToolAliases: payload.missing_required_per_user_tool_aliases || [],
    });
    contextPanel.hydrate({
      activeToolInstances: payload.active_tool_instances || [],
      activeToolBindings: payload.active_tool_bindings || [],
    });
    libraryDraft.hydrate({
      chatBlocks,
      chatToolBindings,
    });
  };

  const loadSettingsState = async () => {
    if (!chatId.value) return;
    const payload = await api.get<ChatSettingsStatePayload>(`/api/bff/chat-state/${chatId.value}/settings`, {
      showErrorBanner: false,
    });
    applySettingsState(payload);
  };

  const loadChat = async (opts: { mode?: 'initial' | 'soft'; includeSettings?: boolean } = {}) => {
    const mode = opts.mode || 'initial';
    const includeSettings = opts.includeSettings !== false;
    if (mode === 'initial') {
      loaded.value = false;
      composerRuntime.stopPolling();
      activeGenerationId.value = null;
      cancelingGenerationId.value = null;
      artifactToolsAvailable.value = false;
      chatBlockCount.value = 0;
      chatToolCount.value = 0;
    }

    loadError.value = '';
    chatUnavailable.value = false;

    const [payload, settingsPayload] = await Promise.all([
      api.get<ChatStatePayload>(`/api/bff/chat-state/${chatId.value}`, {
        showErrorBanner: false,
      }),
      includeSettings
        ? api.get<ChatSettingsStatePayload>(`/api/bff/chat-state/${chatId.value}/settings`, {
            showErrorBanner: false,
          })
        : Promise.resolve(null),
    ]);

    chat.value = payload.chat;
    chatNote.value = payload.chat?.note || '';
    branch.value = payload.branch || [];
    relations.value = payload.relations || emptyChatRelations();
    if (settingsPayload) applySettingsState(settingsPayload);
    chatIdleRevision.value = typeof payload.idle_revision === 'string' ? payload.idle_revision : null;
    composerRuntime.syncServerGenerationState(payload.active_generation_message_id || null);

    loaded.value = true;
    startChatIdlePolling();
    if (mode === 'initial' && !contextPanel.hasFocusMessageQuery()) {
      void scrollToLastMessageIfLayerActive();
    }
  };

  const loadChatSafe = async (opts: { mode?: 'initial' | 'soft'; includeSettings?: boolean } = {}) => {
    try {
      await loadChat(opts);
    } catch (error) {
      chat.value = null;
      branch.value = [];
      relations.value = emptyChatRelations();
      chatIdleRevision.value = null;
      chatBlockCount.value = 0;
      chatToolCount.value = 0;
      if (isHttpError(error) && (error.status === 403 || error.status === 404)) {
        chatUnavailable.value = true;
        loadError.value = '';
      } else {
        console.error(error);
        chatUnavailable.value = false;
        loadError.value = getApiErrorMessage(error, 'Failed to load chat.');
      }
    } finally {
      loaded.value = true;
    }
  };

  const loadInitialChatSafe = async () => {
    await loadChatSafe({ mode: 'initial' });
    if (chatUnavailable.value || !chat.value) return;
    await contextPanel.handleFocusMessage();
  };

  let chatIdlePollTimer: number | null = null;
  let chatIdlePollAbortController: AbortController | null = null;
  let chatIdlePollToken = 0;
  let chatIdlePollingActive = false;
  let chatIdleLastImmediateAt = 0;

  function stopChatIdlePolling() {
    chatIdlePollingActive = false;
    chatIdlePollToken += 1;

    if (chatIdlePollTimer != null) {
      window.clearTimeout(chatIdlePollTimer);
      chatIdlePollTimer = null;
    }

    if (chatIdlePollAbortController) {
      chatIdlePollAbortController.abort();
      chatIdlePollAbortController = null;
    }
  }

  function canRunChatIdleProbe() {
    return (
      loaded.value &&
      Boolean(chat.value) &&
      document.visibilityState === 'visible' &&
      activeGenerationId.value == null
    );
  }

  function chatIdleProbeParams() {
    const params = new URLSearchParams();
    if (chatIdleRevision.value) params.set('revision', chatIdleRevision.value);
    return params;
  }

  async function runChatIdleProbe(signal: AbortSignal) {
    if (!chatId.value || !canRunChatIdleProbe()) return;

    const query = chatIdleProbeParams().toString();
    const suffix = query ? `?${query}` : '';
    const payload = await api.get<ChatIdleStatePayload | undefined>(
      `/api/bff/chat-state/${chatId.value}/idle-state${suffix}`,
      {
        signal,
        showErrorBanner: false,
      }
    );

    if (!payload) return;

    if (typeof payload.revision === 'string') {
      chatIdleRevision.value = payload.revision;
    }

    await loadChatSafe({ mode: 'soft', includeSettings: false });
  }

  function startChatIdlePolling(opts: { immediate?: boolean; throttle?: boolean } = {}) {
    if (chatIdlePollingActive) return;

    chatIdlePollingActive = true;
    const token = ++chatIdlePollToken;

    const scheduleNext = (delayMs: number) => {
      if (!chatIdlePollingActive || chatIdlePollToken !== token) return;
      chatIdlePollTimer = window.setTimeout(() => {
        void tick();
      }, delayMs);
    };

    const tick = async () => {
      if (!chatIdlePollingActive || chatIdlePollToken !== token) return;

      const controller = new AbortController();
      chatIdlePollAbortController = controller;

      try {
        await runChatIdleProbe(controller.signal);
        if (!chatIdlePollingActive || chatIdlePollToken !== token) return;
        scheduleNext(CHAT_IDLE_POLL_DELAY_MS);
      } catch (error) {
        if (!chatIdlePollingActive || chatIdlePollToken !== token) return;
        if (error instanceof DOMException && error.name === 'AbortError') return;
        console.warn('Failed to refresh chat while idle polling.', error);
        scheduleNext(CHAT_IDLE_POLL_RETRY_DELAY_MS);
      } finally {
        if (chatIdlePollAbortController === controller) {
          chatIdlePollAbortController = null;
        }
      }
    };

    if (opts.immediate) {
      const now = Date.now();
      if (!opts.throttle || now - chatIdleLastImmediateAt >= CHAT_IDLE_IMMEDIATE_THROTTLE_MS) {
        chatIdleLastImmediateAt = now;
        void tick();
        return;
      }
    }

    scheduleNext(CHAT_IDLE_POLL_DELAY_MS);
  }

  function restartChatIdlePolling(opts: { immediate?: boolean; throttle?: boolean } = {}) {
    stopChatIdlePolling();
    startChatIdlePolling(opts);
  }

  function handleChatIdleVisibilityChange() {
    if (document.visibilityState !== 'visible') {
      stopChatIdlePolling();
      return;
    }

    restartChatIdlePolling({ immediate: true, throttle: true });
  }

  function handleChatIdlePageShow() {
    restartChatIdlePolling({ immediate: true, throttle: true });
  }

  function handleChatIdleFocus() {
    if (document.visibilityState !== 'visible') return;
    restartChatIdlePolling({ immediate: true, throttle: true });
  }

  const normalizeNumberIds = (ids: unknown): number[] =>
    Array.isArray(ids)
      ? ids.filter((id): id is number => typeof id === 'number' && Number.isInteger(id) && id > 0)
      : [];

  const applyShareState = (state: ChatShareState) => {
    sharedGroupIds.value = normalizeNumberIds(state.group_ids);
    const eligibility = Array.isArray(state.group_eligibility) ? state.group_eligibility : [];
    shareDisabledGroupIds.value = eligibility
      .filter((item) => !item.eligible)
      .map((item) => item.id)
      .filter((id) => Number.isInteger(id) && id > 0);
    shareDisabledGroupReasons.value = Object.fromEntries(
      eligibility
        .filter((item) => !item.eligible && item.disabled_reason)
        .map((item) => [item.id, String(item.disabled_reason)])
    );
  };

  const openShareModal = async () => {
    if (!canEdit.value || !chatId.value || shareLoading.value) return;
    ui.closeMenu();
    shareModalOpen.value = true;
    shareLoading.value = true;
    try {
      const [groupsPayload, state] = await Promise.all([
        api.get<{ groups: Group[] }>('/api/bff/me/groups'),
        api.get<ChatShareState>(`/api/bff/chat-shares/${chatId.value}`),
      ]);
      shareGroups.value = groupsPayload.groups || [];
      applyShareState(state || {});
    } catch (error) {
      console.error(error);
      loadError.value = error instanceof Error ? error.message : 'Failed to load sharing settings.';
    } finally {
      shareLoading.value = false;
    }
  };

  const saveShareGroups = async (groupIds: number[]) => {
    if (!canEdit.value || !chatId.value || shareSaving.value) return;
    shareSaving.value = true;
    try {
      const state = await api.put<ChatShareState>(`/api/bff/chat-shares/${chatId.value}`, {
        group_ids: groupIds,
      });
      applyShareState(state || {});
      shareModalOpen.value = false;
      await loadChatSafe({ mode: 'soft' });
    } catch (error) {
      console.error(error);
      window.alert(error instanceof Error ? error.message : 'Failed to save sharing settings.');
    } finally {
      shareSaving.value = false;
    }
  };

  const continueConversation = async () => {
    if (!sharedReadonly.value || !chatId.value || continuingConversation.value) return;
    continuingConversation.value = true;
    try {
      const nextId = await continueChatRecord(chatId.value);
      await navigateToChat(nextId, { focusComposer: '1' });
    } catch (error) {
      console.error(error);
      window.alert(getApiErrorMessage(error, 'Failed to continue conversation.'));
    } finally {
      continuingConversation.value = false;
    }
  };

  const handoffChat = async () => {
    if (!chatId.value || handoffDisabled.value) return;
    handoffPending.value = true;
    ui.closeMenu();

    try {
      const payload = await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
        `/api/bff/chat-generation/${chatId.value}/handoff`,
        {}
      );
      branch.value = payload.branch || [];
      const messageId = payload.generation?.message_id;
      if (!messageId) throw new Error('Missing generation message id');
      await composerRuntime.startPolling(messageId);
      await loadChatSafe({ mode: 'soft', includeSettings: false });
    } catch (error) {
      console.error(error);
      window.alert(getApiErrorMessage(error, 'Failed to handoff chat.'));
    } finally {
      handoffPending.value = false;
    }
  };

  const backToChats = async () => {
    await goToChats();
  };

  watch(
    () => [ui.leftOpen.value, ui.rightOpen.value, ui.leftTab.value],
    () => ui.persistPanelState(),
    { deep: false }
  );

  watch(
    () => chatId.value,
    () => {
      if (!chatId.value) return;
      stopChatIdlePolling();
      chatIdleRevision.value = null;
      artifactToolsAvailable.value = false;
      contextPanel.resetForChatChange();
      void loadInitialChatSafe();
    }
  );

  watch(
    () => stack.active.value,
    (active, wasActive) => {
      if (!chatId.value) return;
      if (active) return;
      if (wasActive !== true) return;
      void (async () => {
        const handled = await libraryDraft.consumePendingNewBlockContext();
        if (handled) return;
        await loadChatSafe({ mode: 'soft' });
      })();
    }
  );

  const handleKeyNavigation = (event: KeyboardEvent) => {
    if (event.key === 'Escape') {
      if (ui.menuOpen.value) ui.closeMenu();
      if (ui.isMobile.value && (ui.leftOpen.value || ui.rightOpen.value)) ui.closeOverlays();
    }
  };

  onMounted(() => {
    ui.restorePanelState();
    ui.mountListeners(handleKeyNavigation);
    document.addEventListener('visibilitychange', composerRuntime.handleVisibilityChange);
    document.addEventListener('visibilitychange', handleChatIdleVisibilityChange);
    window.addEventListener('pageshow', composerRuntime.handlePageShow);
    window.addEventListener('pageshow', handleChatIdlePageShow);
    window.addEventListener('focus', composerRuntime.handleFocus);
    window.addEventListener('focus', handleChatIdleFocus);
    if (chatId.value) {
      void loadInitialChatSafe();
    }
  });

  onBeforeUnmount(() => {
    stopChatIdlePolling();
    void composerRuntime.dispose();
    void messageActions.dispose();
    contextPanel.dispose();
    inspectors.dispose();
    document.removeEventListener('visibilitychange', composerRuntime.handleVisibilityChange);
    document.removeEventListener('visibilitychange', handleChatIdleVisibilityChange);
    window.removeEventListener('pageshow', composerRuntime.handlePageShow);
    window.removeEventListener('pageshow', handleChatIdlePageShow);
    window.removeEventListener('focus', composerRuntime.handleFocus);
    window.removeEventListener('focus', handleChatIdleFocus);
    ui.unmountListeners();
  });

  return {
    loaded,
    loadError,
    retryLoadChat: loadInitialChatSafe,
    chatUnavailable,
    chat,
    chatNote,
    canEdit,
    sharedReadonly,
    branch,
    parentRelation,
    fallbackChildRelations,
    childRelationsForMessage,
    counters,
    bots,
    llmConfigurations,
    knowledgeBlocks,
    selectableConfigs: headerControls.selectableConfigs,
    defaultConfig: headerControls.defaultConfig,
    regularSelectableConfigs: headerControls.regularSelectableConfigs,
    moreConfigs: headerControls.moreConfigs,
    selectedConfig: headerControls.selectedConfig,
    appliedConfig: headerControls.appliedConfig,
    configSyncStatus: headerControls.configSyncStatus,
    configSyncError: headerControls.configSyncError,
    isConfigSyncPending: headerControls.isConfigSyncPending,
    selectedDisabledConfig: headerControls.selectedDisabledConfig,
    selectedDisabledConfigReason: headerControls.selectedDisabledConfigReason,
    configLabel: headerControls.configLabel,
    editConfigLabel: headerControls.editConfigLabel,
    menuOpen: ui.menuOpen,
    menuStyle: ui.menuStyle,
    currentBotId: headerControls.currentBotId,
    currentBotName: headerControls.currentBotName,
    chatBaseTitle: headerControls.chatBaseTitle,
    chatFullTitle: headerControls.chatFullTitle,
    canAttachFiles: headerControls.canAttachFiles,
    fileInputAccept: headerControls.fileInputAccept,
    fileAttachTitle: headerControls.fileAttachTitle,
    fileDropHint: headerControls.fileDropHint,
    showMissingToolsBanner: headerControls.showMissingToolsBanner,
    missingRequiredPerUserToolAliases: headerControls.missingRequiredPerUserToolAliases,
    leftOpen: ui.leftOpen,
    rightOpen: ui.rightOpen,
    leftTab: ui.leftTab,
    isMobile: ui.isMobile,
    gridColumns: ui.gridColumns,
    toggleMenu: ui.toggleMenu,
    setMenuRef,
    setMenuAnchorRef,
    setMenuButtonRef,
    openConfigEditor: headerControls.openConfigEditor,
    openBotEditor: headerControls.openBotEditor,
    openBotTools: headerControls.openBotTools,
    dismissMissingToolsBanner: headerControls.dismissMissingToolsBanner,
    openShareModal,
    shareModalOpen,
    shareGroups,
    sharedGroupIds,
    shareDisabledGroupIds,
    shareDisabledGroupReasons,
    shareLoading,
    shareSaving,
    saveShareGroups,
    continuingConversation,
    continueConversation,
    handoffPending,
    handoffDisabled,
    handoffChat,
    chatsReturnTarget,
    openChat: navigateToChat,
    backToChats,
    closeOverlays: ui.closeOverlays,
    promptTokenCount: contextPanel.promptTokenCount,
    historyTokenCount: contextPanel.historyTokenCount,
    totalTokenCount: contextPanel.totalTokenCount,
    showContextUsageIndicator: contextPanel.showContextUsageIndicator,
    contextUsagePercentRounded: contextPanel.contextUsagePercentRounded,
    contextUsageTitle: contextPanel.contextUsageTitle,
    isContextSoftLimitReached: contextPanel.isContextSoftLimitReached,
    contextUsagePercent: contextPanel.contextUsagePercent,
    isAgentHistoryMode: contextPanel.isAgentHistoryMode,
    agentContextTokenCount: contextPanel.agentContextTokenCount,
    branchSearchTerm: contextPanel.branchSearchTerm,
    hasBranchSearch: contextPanel.hasBranchSearch,
    branchSearchLoading: contextPanel.branchSearchLoading,
    branchSearchError: contextPanel.branchSearchError,
    branchSearchResults: contextPanel.branchSearchResults,
    linkedBlocks: contextPanel.linkedBlocks,
    SOURCE_LABELS,
    botToolsLoading: contextPanel.botToolsLoading,
    botToolsError: contextPanel.botToolsError,
    activeToolInstances: contextPanel.activeToolInstances,
    activeToolBindings: contextPanel.activeToolBindings,
    formatStepMetric: contextPanel.formatStepMetric,
    searchHitMeta: contextPanel.searchHitMeta,
    messageMetaLabel: contextPanel.messageMetaLabel,
    messagePrimaryText: messageActions.messagePrimaryText,
    preview: contextPanel.preview,
    hasBlockVersion: contextPanel.hasBlockVersion,
    formatBlockVersion: contextPanel.formatBlockVersion,
    handleBranchItemClick: contextPanel.handleBranchItemClick,
    handleSearchResultClick: contextPanel.handleSearchResultClick,
    switchBranchHandler: messageActions.switchBranchHandler,
    openContextBlockEditor: contextPanel.openContextBlockEditor,
    openContextToolEditor: contextPanel.openContextToolEditor,
    chatWindowRef: contextPanel.chatWindowRef,
    setMessageRef: contextPanel.setMessageRef,
    copiedMessageId: messageActions.copiedMessageId,
    retryingMessageId: messageActions.retryingMessageId,
    branchingAssistantId: messageActions.branchingAssistantId,
    branchingNewChatMessageId: messageActions.branchingNewChatMessageId,
    movingBranchToNewChatMessageId: messageActions.movingBranchToNewChatMessageId,
    isBookmarkingMessage: messageActions.isBookmarkingMessage,
    isWorkingOpen: messageActions.isWorkingOpen,
    workingStateFor: messageActions.workingStateFor,
    toggleWorking: messageActions.toggleWorking,
    selectWorkingStep: messageActions.selectWorkingStep,
    canDeleteMessage: messageActions.canDeleteMessage,
    deleteMessageTitle: messageActions.deleteMessageTitle,
    copyMessage: messageActions.copyMessage,
    toggleBookmark: messageActions.toggleBookmark,
    startEdit: messageActions.startEdit,
    startBranch: messageActions.startBranch,
    startBranchToNewChat: messageActions.startBranchToNewChat,
    moveBranchToNewChat: messageActions.moveBranchToNewChat,
    retryLastStep: messageActions.retryLastStep,
    confirmAndDeleteMessage: messageActions.confirmAndDeleteMessage,
    draft: composerRuntime.draft,
    pendingFiles: composerRuntime.pendingFiles,
    addPendingFiles: composerRuntime.addPendingFiles,
    onPendingFilesSelected: composerRuntime.onPendingFilesSelected,
    removePendingFile: composerRuntime.removePendingFile,
    sending: composerRuntime.sending,
    sendButtonLabel: composerRuntime.sendButtonLabel,
    activeGenerationId,
    cancelingGenerationId,
    generationPollReconnecting: composerRuntime.generationPollReconnecting,
    handleCancelPointerDown: composerRuntime.handleCancelPointerDown,
    send: composerRuntime.send,
    cancelActiveGeneration: composerRuntime.cancelActiveGeneration,
    editingMessage: messageActions.editingMessage,
    modalMode: messageActions.modalMode,
    editContents: messageActions.editContents,
    editExistingAttachments: messageActions.editExistingAttachments,
    editPendingFiles: messageActions.editPendingFiles,
    editError: messageActions.editError,
    editAttachmentHelp: headerControls.fileAttachTitle,
    savingEdit: messageActions.savingEdit,
    editSaveLabel: messageActions.editSaveLabel,
    cancelEdit: messageActions.cancelEdit,
    addEditPendingFiles: messageActions.addEditPendingFiles,
    removeEditPendingFile: messageActions.removeEditPendingFile,
    removeEditExistingAttachment: messageActions.removeEditExistingAttachment,
    saveEdit: messageActions.saveEdit,
    promptModalOpen: inspectors.promptModalOpen,
    promptLoading: inspectors.promptLoading,
    promptError: inspectors.promptError,
    promptText: inspectors.promptText,
    openPromptModal: inspectors.openPromptModal,
    closePromptModal: inspectors.closePromptModal,
    noteModalOpen: headerControls.noteModalOpen,
    noteModalValue: headerControls.noteModalValue,
    savingNote: headerControls.savingNote,
    openNoteModal: headerControls.openNoteModal,
    closeNoteModal: headerControls.closeNoteModal,
    saveNote: headerControls.saveNote,
    stepDetailsOpen: inspectors.stepDetailsOpen,
    stepDetailsStep: inspectors.stepDetailsStep,
    stepDetailsMessageId: inspectors.stepDetailsMessageId,
    stepDetailsMessageStatus: inspectors.stepDetailsMessageStatus,
    stepDetailsShowBilling: inspectors.stepDetailsShowBilling,
    stepDetailsShowResponse: inspectors.stepDetailsShowResponse,
    stepDetailsRetryFromStepPending: inspectors.stepDetailsRetryFromStepPending,
    stepDetailsRequestLoading: inspectors.stepDetailsRequestLoading,
    stepDetailsRequestError: inspectors.stepDetailsRequestError,
    stepDetailsRequestPayload: inspectors.stepDetailsRequestPayload,
    stepDetailsResponseLoading: inspectors.stepDetailsResponseLoading,
    stepDetailsResponseError: inspectors.stepDetailsResponseError,
    stepDetailsResponsePayload: inspectors.stepDetailsResponsePayload,
    openStepDetails: inspectors.openStepDetails,
    closeStepDetails: inspectors.closeStepDetails,
    retryFromStep: inspectors.retryFromStep,
    contentFullOpen: inspectors.contentFullOpen,
    contentFullTitle: inspectors.contentFullTitle,
    contentFullLoading: inspectors.contentFullLoading,
    contentFullError: inspectors.contentFullError,
    contentFullText: inspectors.contentFullText,
    openContentFull: inspectors.openContentFull,
    closeContentFull: inspectors.closeContentFull,
    attachmentPreviewOpen: inspectors.attachmentPreviewOpen,
    attachmentPreviewTitle: inspectors.attachmentPreviewTitle,
    attachmentPreviewUrl: inspectors.attachmentPreviewUrl,
    attachmentPreviewKind: inspectors.attachmentPreviewKind,
    attachmentPreviewLoading: inspectors.attachmentPreviewLoading,
    attachmentPreviewDownloadPending: inspectors.attachmentPreviewDownloadPending,
    attachmentPreviewError: inspectors.attachmentPreviewError,
    attachmentPreviewText: inspectors.attachmentPreviewText,
    attachmentPreviewCanNavigate: inspectors.attachmentPreviewCanNavigate,
    openAttachmentPreview: inspectors.openAttachmentPreview,
    openPendingAttachmentPreview: inspectors.openPendingAttachmentPreview,
    openExistingAttachmentPreview: inspectors.openExistingAttachmentPreview,
    showPreviousAttachmentPreview: inspectors.showPreviousAttachmentPreview,
    showNextAttachmentPreview: inspectors.showNextAttachmentPreview,
    downloadAttachmentPreview: inspectors.downloadAttachmentPreview,
    closeAttachmentPreview: inspectors.closeAttachmentPreview,
    botModalOpen: headerControls.botModalOpen,
    botModalValue: headerControls.botModalValue,
    savingBot: headerControls.savingBot,
    openBotModal: headerControls.openBotModal,
    closeBotModal: headerControls.closeBotModal,
    saveBotSelection: headerControls.saveBotSelection,
    creatingChat: headerControls.creatingChat,
    newChatModalOpen: headerControls.newChatModalOpen,
    newChatBotValue: headerControls.newChatBotValue,
    botSelectionOptions: headerControls.botSelectionOptions,
    createChatBotOptions: headerControls.createChatBotOptions,
    openNewChatModal: headerControls.openNewChatModal,
    closeNewChatModal: headerControls.closeNewChatModal,
    createChat: headerControls.createChat,
    deleting: ui.deleting,
    removeChat: headerControls.removeChat,
    chatTabDirty: libraryDraft.chatTabDirty,
    savingChatChanges: libraryDraft.savingChatChanges,
    chatBlocks: libraryDraft.chatBlocks,
    chatToolBindings: libraryDraft.chatToolBindings,
    toolLibrary,
    newChatToolInstanceIds: libraryDraft.newChatToolInstanceIds,
    chatBlockName: libraryDraft.chatBlockName,
    chatBlockImage: libraryDraft.chatBlockImage,
    chatBlockVersion: libraryDraft.chatBlockVersion,
    chatBlockTokenCount: libraryDraft.chatBlockTokenCount,
    chatBlockMeta: libraryDraft.chatBlockMeta,
    toolLabel: libraryDraft.toolLabel,
    toolTypeLabel: libraryDraft.toolTypeLabel,
    toolIsOutlet: libraryDraft.toolIsOutlet,
    toolIsOnline: libraryDraft.toolIsOnline,
    saveChatChanges: libraryDraft.saveChatChanges,
    cancelChatChanges: libraryDraft.cancelChatChanges,
    openChatBlocksPicker: libraryDraft.openChatBlocksPicker,
    openNewBlock: libraryDraft.openNewBlock,
    openChatBlockEditor: libraryDraft.openChatBlockEditor,
    openChatToolEditor: libraryDraft.openChatToolEditor,
    addChatToolBinding: libraryDraft.addChatToolBinding,
    moveChatBlock: libraryDraft.moveChatBlock,
    moveChatToolBinding: libraryDraft.moveChatToolBinding,
    removeChatBlock: libraryDraft.removeChatBlock,
    removeChatToolBinding: libraryDraft.removeChatToolBinding,
    setChatBlockEnabled: libraryDraft.setChatBlockEnabled,
    setChatToolBindingEnabled: libraryDraft.setChatToolBindingEnabled,
    chatBlocksPickerOpen: libraryDraft.chatBlocksPickerOpen,
    chatBlocksPickerSelection: libraryDraft.chatBlocksPickerSelection,
    linkedChatBlockIds: libraryDraft.linkedChatBlockIds,
    addChatBlocks: libraryDraft.addChatBlocks,
    compiledPromptText,
    updateConfig: headerControls.updateConfig,
  };
}
