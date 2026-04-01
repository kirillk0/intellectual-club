import { computed, ref, type ComputedRef, type Ref } from 'vue';

import { api } from '@/api/client';
import {
  describeChatUploadPolicy,
  resolveChatUploadPolicy,
} from '@/features/chat/attachments';
import { normalizeIdList } from '@/features/chat/model/chatViewModel.shared';
import type { Bot, Chat, LlmConfiguration } from '@/types/api';

type Params = {
  chatId: ComputedRef<number>;
  routeFullPath: () => string;
  chat: Ref<Chat | null>;
  chatNote: Ref<string>;
  bots: Ref<Bot[]>;
  llmConfigurations: Ref<LlmConfiguration[]>;
  activeGenerationId: Ref<number | null>;
  menuOpen: Ref<boolean>;
  deleting: Ref<boolean>;
  exporting: Ref<boolean>;
  duplicating: Ref<boolean>;
  toggleMenu: () => void;
  closeMenu: () => void;
  stackOpen: (payload: { path: string; query?: Record<string, string> }) => void;
  pushRoute: (path: string) => Promise<unknown>;
  reloadChat: () => Promise<void>;
  refreshPromptContext: () => Promise<void>;
};

export function useChatHeaderControls(params: Params) {
  const selectedConfig = ref<number | ''>('');
  const configSyncStatus = ref<'synced' | 'pending' | 'error'>('synced');
  const configSyncError = ref('');
  let configSyncToken = 0;

  const showMissingToolsBanner = ref(false);
  const missingRequiredPerUserToolAliases = ref<string[]>([]);

  const appliedConfig = computed<number | ''>(() => params.chat.value?.llm_configuration_id ?? '');
  const isConfigSyncPending = computed(() => configSyncStatus.value === 'pending');

  const currentConfig = computed(() => {
    const cfgId = selectedConfig.value || params.chat.value?.llm_configuration_id || null;
    if (!cfgId) return null;
    return (params.llmConfigurations.value || []).find((config) => config.id === Number(cfgId)) || null;
  });

  const configLabel = (cfg: LlmConfiguration) => {
    const prefix = cfg.shared_incoming ? '📥 ' : cfg.shared_outgoing ? '📤 ' : '';
    return `${prefix}${cfg.label || `Config #${cfg.id}`}`;
  };

  const messageConfigLabel = (configId?: number | null) => {
    if (!configId) return '';
    const cfg = (params.llmConfigurations.value || []).find((item) => item.id === configId);
    return cfg ? configLabel(cfg) : `Config #${configId}`;
  };

  const editConfigLabel = computed(() => 'Edit configuration');

  const currentBotId = computed(() => params.chat.value?.bot_id ?? null);
  const currentBotInfo = computed(() => {
    const id = currentBotId.value;
    if (!id) return null;
    return (params.bots.value || []).find((bot) => bot.id === id) || null;
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
    const enabledConfigs = (params.llmConfigurations.value || []).filter((config) => config.enabled);
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

    const selected = (params.llmConfigurations.value || []).find((config) => config.id === Number(selectedConfig.value));
    if (!selected) return null;
    if (!selected.enabled) return 'disabled';
    return selectableConfigs.value.some((config) => config.id === selected.id) ? null : 'incompatible';
  });
  const selectedDisabledConfig = computed(() => {
    if (!selectedConfig.value || !selectedDisabledConfigReason.value) return null;
    return (params.llmConfigurations.value || []).find((config) => config.id === Number(selectedConfig.value)) || null;
  });

  const canAttachFiles = computed(() => fileUploadPolicy.value.allowsFiles);
  const fileInputAccept = computed(() => fileUploadPolicy.value.accept);
  const fileAttachTitle = computed(() => describeChatUploadPolicy(fileUploadPolicy.value));
  const fileDropHint = computed(() =>
    fileUploadPolicy.value.imagesOnly ? 'Drop images here to attach them' : 'Drop files here to attach them'
  );

  const hydrate = (payload: {
    selectedConfig: number | '';
    missingRequiredPerUserToolAliases: string[];
  }) => {
    selectedConfig.value = payload.selectedConfig;
    configSyncStatus.value = 'synced';
    configSyncError.value = '';
    missingRequiredPerUserToolAliases.value = payload.missingRequiredPerUserToolAliases || [];
    showMissingToolsBanner.value = missingRequiredPerUserToolAliases.value.length > 0;
  };

  const noteModalOpen = ref(false);
  const noteModalValue = ref('');
  const savingNote = ref(false);

  const openNoteModal = () => {
    noteModalValue.value = params.chatNote.value || '';
    noteModalOpen.value = true;
  };

  const closeNoteModal = () => {
    noteModalOpen.value = false;
  };

  const saveNote = async () => {
    if (!params.chatId.value || savingNote.value) return;
    savingNote.value = true;
    try {
      const nextNote = noteModalValue.value.trim();
      await api.patch(`/api/bff/chats/${params.chatId.value}`, { note: nextNote });
      params.chatNote.value = nextNote;
      closeNoteModal();
    } catch (error) {
      console.error(error);
      window.alert('Failed to save note.');
    } finally {
      savingNote.value = false;
    }
  };

  const botModalOpen = ref(false);
  const botModalValue = ref<number | ''>('');
  const savingBot = ref(false);

  const openBotModal = () => {
    botModalValue.value = params.chat.value?.bot_id ?? '';
    botModalOpen.value = true;
  };

  const closeBotModal = () => {
    botModalOpen.value = false;
  };

  const saveBotSelection = async () => {
    if (!params.chatId.value || savingBot.value) return;
    savingBot.value = true;
    try {
      const botId = botModalValue.value === '' ? null : Number(botModalValue.value);
      await api.patch(`/api/bff/chats/${params.chatId.value}`, { bot_id: botId });
      await params.reloadChat();
      closeBotModal();
    } catch (error) {
      console.error(error);
      window.alert('Failed to update bot.');
    } finally {
      savingBot.value = false;
    }
  };

  const updateConfig = async () => {
    if (!params.chatId.value) return;
    if (params.activeGenerationId.value) {
      window.alert('Cannot change configuration while generating a response.');
      selectedConfig.value = appliedConfig.value;
      return;
    }
    if (isConfigSyncPending.value) return;

    const token = (configSyncToken += 1);
    configSyncStatus.value = 'pending';
    configSyncError.value = '';

    const cfgId = selectedConfig.value === '' ? null : Number(selectedConfig.value);

    try {
      const payload = await api.patch<{ chat: Chat }>(`/api/bff/chats/${params.chatId.value}`, {
        llm_configuration_id: cfgId,
      });

      if (configSyncToken !== token) return;
      params.chat.value = payload.chat;
      selectedConfig.value = payload.chat?.llm_configuration_id ?? '';
      await params.refreshPromptContext();
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
    params.stackOpen({
      path: `/catalogs/llm-configurations/${selectedConfig.value}`,
      query: { returnTo: params.routeFullPath() },
    });
    params.closeMenu();
  };

  const openBotEditor = () => {
    if (!currentBotId.value) return;
    params.stackOpen({
      path: `/catalogs/bots/${currentBotId.value}`,
      query: { returnTo: params.routeFullPath() },
    });
    params.closeMenu();
  };

  const openBotTools = () => {
    window.alert('Not implemented yet.');
    params.closeMenu();
  };

  const dismissMissingToolsBanner = () => {
    showMissingToolsBanner.value = false;
  };

  const duplicateActiveBranch = async () => {
    window.alert('Not implemented yet.');
  };

  const exportMarkdown = async () => {
    window.alert('Not implemented yet.');
  };

  const exportYaml = async () => {
    window.alert('Not implemented yet.');
  };

  const removeChat = async () => {
    if (!params.chatId.value || params.deleting.value) return;
    const ok = window.confirm('Delete this chat? All messages will be removed.');
    if (!ok) {
      params.closeMenu();
      return;
    }
    params.deleting.value = true;
    try {
      await api.del(`/api/bff/chats/${params.chatId.value}`);
      params.closeMenu();
      await params.pushRoute('/');
    } finally {
      params.deleting.value = false;
    }
  };

  return {
    selectedConfig,
    configSyncStatus,
    configSyncError,
    appliedConfig,
    isConfigSyncPending,
    currentConfig,
    configLabel,
    messageConfigLabel,
    editConfigLabel,
    currentBotId,
    currentBotInfo,
    currentBotName,
    fileUploadPolicy,
    selectableConfigs,
    selectedDisabledConfig,
    selectedDisabledConfigReason,
    canAttachFiles,
    fileInputAccept,
    fileAttachTitle,
    fileDropHint,
    showMissingToolsBanner,
    missingRequiredPerUserToolAliases,
    hydrate,
    noteModalOpen,
    noteModalValue,
    savingNote,
    openNoteModal,
    closeNoteModal,
    saveNote,
    botModalOpen,
    botModalValue,
    savingBot,
    openBotModal,
    closeBotModal,
    saveBotSelection,
    updateConfig,
    openConfigEditor,
    openBotEditor,
    openBotTools,
    dismissMissingToolsBanner,
    duplicateActiveBranch,
    exportMarkdown,
    exportYaml,
    removeChat,
  };
}
