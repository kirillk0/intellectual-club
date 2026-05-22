import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';

import { api, getApiErrorMessage, isHttpError } from '@/api/client';
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
  type ChatStatePayload,
  type Counters,
} from '@/features/chat/model/chatViewModel.shared';
import { SOURCE_LABELS } from '@/features/chat/types';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import { usePageTitleOverride } from '@/features/app/documentTitle';
import type {
  Bot,
  Chat,
  ChatBranchMessage,
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

export function useChatViewModel() {
  const route = useRoute();
  const router = useRouter();
  const stackNav = useStackNavigation();
  const stack = useNavigationStack();
  const chatId = computed(() => Number(route.params.id));

  const ui = useChatUiChrome();

  const loaded = ref(false);
  const loadError = ref('');
  const chatUnavailable = ref(false);

  const chat = ref<Chat | null>(null);
  const chatNote = ref('');
  const canEdit = computed(() => chat.value?.can_edit !== false);
  const sharedReadonly = computed(() => chat.value?.can_edit === false && chat.value?.shared_incoming === true);
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
  const promptBlocks = ref<ChatStatePayload['prompt_blocks']>([]);
  const compiledPromptText = ref('');

  const bots = ref<Bot[]>([]);
  const llmConfigurations = ref<LlmConfiguration[]>([]);
  const knowledgeBlocks = ref<KnowledgeBlock[]>([]);
  const toolLibrary = ref<ToolInstanceOption[]>([]);

  const activeGenerationId = ref<number | null>(null);
  const cancelingGenerationId = ref<number | null>(null);
  const chatIdleRevision = ref<string | null>(null);
  const continuingConversation = ref(false);

  const shareModalOpen = ref(false);
  const shareGroups = ref<Group[]>([]);
  const sharedGroupIds = ref<number[]>([]);
  const shareDisabledGroupIds = ref<number[]>([]);
  const shareDisabledGroupReasons = ref<Record<number, string>>({});
  const shareLoading = ref(false);
  const shareSaving = ref(false);

  const setMenuRef = (el: Element | null) => {
    ui.menuRef.value = el as HTMLElement | null;
  };

  const setMenuAnchorRef = (el: Element | null) => {
    ui.menuAnchorRef.value = el as HTMLElement | null;
  };

  const setMenuButtonRef = (el: Element | null) => {
    ui.menuButtonRef.value = el as HTMLElement | null;
  };

  const refreshPromptContextFromServer = async () => {
    if (!chatId.value) return;
    const payload = await api.get<ChatPromptContextPayload>(`/api/bff/chats/${chatId.value}/prompt-context`);
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
    llmConfigurations,
    activeGenerationId,
    menuOpen: ui.menuOpen,
    deleting: ui.deleting,
    toggleMenu: ui.toggleMenu,
    closeMenu: ui.closeMenu,
    stackOpen: stackNav.open,
    pushRoute: (path) => router.push(path),
    reloadChat: () => loadChat({ mode: 'soft' }),
    refreshPromptContext: () => refreshPromptContextFromServer(),
  });
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

  const composerRuntime = useChatComposerRuntime({
    chatId,
    branch,
    readOnly: sharedReadonly,
    loadError,
    fileUploadPolicy: headerControls.fileUploadPolicy,
    waitForConfigSync: headerControls.waitForConfigSync,
    activeGenerationId,
    cancelingGenerationId,
    scrollToLastMessage: contextPanel.scrollToLastMessage,
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
    scrollToLastMessage: contextPanel.scrollToLastMessage,
    ensurePendingFilesUploaded: composerRuntime.ensurePendingFilesUploaded,
    removePendingFileFromCollection: composerRuntime.removePendingFileFromCollection,
    clearPendingFilesCollection: composerRuntime.clearPendingFilesCollection,
    afterBranchSwitched: contextPanel.rerunBranchSearch,
  });

  const inspectors = useChatInspectors({
    compiledPromptText,
    loadError,
    branch,
    branchMessageById: messageActions.branchMessageById,
    retryConfigurationWarning: messageActions.retryConfigurationWarning,
    startPolling: composerRuntime.startPolling,
    scrollToLastMessage: contextPanel.scrollToLastMessage,
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

  const loadChat = async (opts: { mode?: 'initial' | 'soft' } = {}) => {
    const mode = opts.mode || 'initial';
    if (mode === 'initial') {
      loaded.value = false;
      composerRuntime.stopPolling();
      activeGenerationId.value = null;
      cancelingGenerationId.value = null;
    }

    loadError.value = '';
    chatUnavailable.value = false;

    const payload = await api.get<ChatStatePayload>(`/api/bff/chats/${chatId.value}/state`, {
      showErrorBanner: false,
    });

    chat.value = payload.chat;
    chatNote.value = payload.chat?.note || '';
    branch.value = payload.branch || [];
    counters.value = payload.counters || counters.value;
    promptSources.value = payload.prompt_sources || promptSources.value;
    promptBlocks.value = payload.prompt_blocks || [];
    compiledPromptText.value = payload.compiled_prompt_text || '';

    bots.value = payload.options?.bots || [];
    llmConfigurations.value = payload.options?.llm_configurations || [];
    knowledgeBlocks.value = payload.options?.knowledge_blocks || [];
    toolLibrary.value = payload.options?.tool_instances || [];

    headerControls.hydrate({
      selectedConfig: payload.chat?.llm_configuration_id ?? '',
      missingRequiredPerUserToolAliases: payload.missing_required_per_user_tool_aliases || [],
    });
    contextPanel.hydrate({
      activeToolInstances: payload.active_tool_instances || [],
      activeToolBindings: payload.active_tool_bindings || [],
    });
    libraryDraft.hydrate({
      chatBlocks: payload.chat_blocks || [],
      chatToolBindings: payload.chat_tool_bindings || [],
      chatVariables: payload.chat?.variables || [],
    });
    chatIdleRevision.value = typeof payload.idle_revision === 'string' ? payload.idle_revision : null;
    composerRuntime.syncServerGenerationState(payload.active_generation_message_id || null);

    loaded.value = true;
    startChatIdlePolling();
    if (mode === 'initial' && !contextPanel.hasFocusMessageQuery()) {
      void contextPanel.scrollToLastMessage();
    }
  };

  const loadChatSafe = async (opts: { mode?: 'initial' | 'soft' } = {}) => {
    try {
      await loadChat(opts);
    } catch (error) {
      chat.value = null;
      branch.value = [];
      chatIdleRevision.value = null;
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
      `/api/bff/chats/${chatId.value}/idle-state${suffix}`,
      {
        signal,
        showErrorBanner: false,
      }
    );

    if (!payload) return;

    if (typeof payload.revision === 'string') {
      chatIdleRevision.value = payload.revision;
    }

    await loadChatSafe({ mode: 'soft' });
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
        api.get<ChatShareState>(`/api/bff/chats/${chatId.value}/shares`),
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
      const state = await api.put<ChatShareState>(`/api/bff/chats/${chatId.value}/shares`, {
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
      const payload = await api.post<{ chat: { id: number } }>(`/api/bff/chats/${chatId.value}/continue`, {});
      const nextId = payload.chat?.id;
      if (!nextId) throw new Error('Missing chat id');
      await router.push(`/chats/${nextId}`);
    } catch (error) {
      console.error(error);
      window.alert(getApiErrorMessage(error, 'Failed to continue conversation.'));
    } finally {
      continuingConversation.value = false;
    }
  };

  const backToChats = async () => {
    await router.push('/chats');
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
      contextPanel.resetForChatChange();
      void (async () => {
        await loadChatSafe();
        if (chatUnavailable.value || !chat.value) return;
        await contextPanel.handleFocusMessage();
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
      void (async () => {
        await loadChatSafe();
        if (chatUnavailable.value || !chat.value) return;
        await contextPanel.handleFocusMessage();
      })();
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
    chatUnavailable,
    chat,
    chatNote,
    canEdit,
    sharedReadonly,
    branch,
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
    isBookmarkingMessage: messageActions.isBookmarkingMessage,
    isWorkingOpen: messageActions.isWorkingOpen,
    toggleWorking: messageActions.toggleWorking,
    canDeleteMessage: messageActions.canDeleteMessage,
    deleteMessageTitle: messageActions.deleteMessageTitle,
    copyMessage: messageActions.copyMessage,
    toggleBookmark: messageActions.toggleBookmark,
    startEdit: messageActions.startEdit,
    startBranch: messageActions.startBranch,
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
    attachmentPreviewError: inspectors.attachmentPreviewError,
    attachmentPreviewText: inspectors.attachmentPreviewText,
    attachmentPreviewCanNavigate: inspectors.attachmentPreviewCanNavigate,
    openAttachmentPreview: inspectors.openAttachmentPreview,
    openPendingAttachmentPreview: inspectors.openPendingAttachmentPreview,
    openExistingAttachmentPreview: inspectors.openExistingAttachmentPreview,
    showPreviousAttachmentPreview: inspectors.showPreviousAttachmentPreview,
    showNextAttachmentPreview: inspectors.showNextAttachmentPreview,
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
    chatVariables: libraryDraft.chatVariables,
    toolLibrary,
    newChatToolInstanceIds: libraryDraft.newChatToolInstanceIds,
    chatBlockName: libraryDraft.chatBlockName,
    chatBlockImage: libraryDraft.chatBlockImage,
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
    setChatToolBindingEnabled: libraryDraft.setChatToolBindingEnabled,
    touchChatBlocks: libraryDraft.touchChatBlocks,
    addVariableRow: libraryDraft.addVariableRow,
    chatBlocksPickerOpen: libraryDraft.chatBlocksPickerOpen,
    chatBlocksPickerSelection: libraryDraft.chatBlocksPickerSelection,
    linkedChatBlockIds: libraryDraft.linkedChatBlockIds,
    addChatBlocks: libraryDraft.addChatBlocks,
    compiledPromptText,
    updateConfig: headerControls.updateConfig,
  };
}
