import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';

import { api } from '@/api/client';
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
  type ChatStatePayload,
  type Counters,
} from '@/features/chat/model/chatViewModel.shared';
import { SOURCE_LABELS } from '@/features/chat/types';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import type {
  Bot,
  Chat,
  ChatBranchMessage,
  KnowledgeBlock,
  LlmConfiguration,
  ToolInstanceOption,
} from '@/types/api';

export function useChatViewModel() {
  const route = useRoute();
  const router = useRouter();
  const stackNav = useStackNavigation();
  const stack = useNavigationStack();
  const chatId = computed(() => Number(route.params.id));

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
  const toolLibrary = ref<ToolInstanceOption[]>([]);

  const activeGenerationId = ref<number | null>(null);
  const cancelingGenerationId = ref<number | null>(null);

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
    const payload = await api.get<ChatStatePayload>(`/api/bff/chats/${chatId.value}/state`);
    promptSources.value = payload.prompt_sources || promptSources.value;
    compiledPromptText.value = payload.compiled_prompt_text || '';
    counters.value = payload.counters || counters.value;
  };

  const headerControls = useChatHeaderControls({
    chatId,
    routeFullPath: () => route.fullPath,
    chat,
    chatNote,
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

  const contextPanel = useChatContextPanel({
    chatId,
    branch,
    promptSources,
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
    findPendingAttachment: (fileId) =>
      composerRuntime.findPendingFile(composerRuntime.pendingFiles, fileId) ||
      composerRuntime.findPendingFile(messageActions.editPendingFiles, fileId),
  });

  const libraryDraft = useChatLibraryDraft({
    chatId,
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
    toolLibrary.value = payload.options?.tool_instances || [];

    headerControls.hydrate({
      selectedConfig: payload.chat?.llm_configuration_id ?? '',
      missingRequiredPerUserToolAliases: payload.missing_required_per_user_tool_aliases || [],
    });
    contextPanel.hydrate({
      activeToolInstances: payload.active_tool_instances || [],
    });
    libraryDraft.hydrate({
      chatBlocks: payload.chat_blocks || [],
      chatToolBindings: payload.chat_tool_bindings || [],
      chatVariables: payload.chat?.variables || [],
    });
    composerRuntime.syncServerGenerationState(payload.active_generation_message_id || null);

    loaded.value = true;
    if (mode === 'initial' && !contextPanel.hasFocusMessageQuery()) {
      void contextPanel.scrollToLastMessage();
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
    () => [ui.leftOpen.value, ui.rightOpen.value, ui.leftTab.value],
    () => ui.persistPanelState(),
    { deep: false }
  );

  watch(
    () => chatId.value,
    () => {
      if (!chatId.value) return;
      contextPanel.resetForChatChange();
      void (async () => {
        await loadChatSafe();
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
    window.addEventListener('pageshow', composerRuntime.handlePageShow);
    window.addEventListener('focus', composerRuntime.handleFocus);
    if (chatId.value) {
      void (async () => {
        await loadChatSafe();
        await contextPanel.handleFocusMessage();
      })();
    }
  });

  onBeforeUnmount(() => {
    void composerRuntime.dispose();
    void messageActions.dispose();
    contextPanel.dispose();
    inspectors.dispose();
    document.removeEventListener('visibilitychange', composerRuntime.handleVisibilityChange);
    window.removeEventListener('pageshow', composerRuntime.handlePageShow);
    window.removeEventListener('focus', composerRuntime.handleFocus);
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
    selectableConfigs: headerControls.selectableConfigs,
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
    openAttachmentPreview: inspectors.openAttachmentPreview,
    openPendingAttachmentPreview: inspectors.openPendingAttachmentPreview,
    openExistingAttachmentPreview: inspectors.openExistingAttachmentPreview,
    closeAttachmentPreview: inspectors.closeAttachmentPreview,
    botModalOpen: headerControls.botModalOpen,
    botModalValue: headerControls.botModalValue,
    savingBot: headerControls.savingBot,
    openBotModal: headerControls.openBotModal,
    closeBotModal: headerControls.closeBotModal,
    saveBotSelection: headerControls.saveBotSelection,
    deleting: ui.deleting,
    removeChat: headerControls.removeChat,
    chatTabDirty: libraryDraft.chatTabDirty,
    savingChatChanges: libraryDraft.savingChatChanges,
    chatBlocks: libraryDraft.chatBlocks,
    chatToolBindings: libraryDraft.chatToolBindings,
    chatVariables: libraryDraft.chatVariables,
    toolLibrary,
    newChatToolInstanceId: libraryDraft.newChatToolInstanceId,
    newChatToolAlias: libraryDraft.newChatToolAlias,
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
