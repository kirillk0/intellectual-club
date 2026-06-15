import { computed, ref, type ComputedRef, type Ref } from 'vue';

import { api } from '@/api/client';
import {
  describeChatUploadPolicy,
  resolveChatUploadPolicy,
} from '@/features/chat/attachments';
import { normalizeIdList, normalizeNameList } from '@/features/chat/model/chatViewModel.shared';
import type { Bot, Chat, LlmConfiguration } from '@/types/api';
import { formatChatBaseTitle, formatChatFullTitle } from '@/utils/chatTitle';

const CONFIG_SYNC_GRACE_PERIOD_MS = 2500;

type Params = {
  chatId: ComputedRef<number>;
  routeFullPath: () => string;
  chat: Ref<Chat | null>;
  chatNote: Ref<string>;
  canEdit: ComputedRef<boolean>;
  bots: Ref<Bot[]>;
  noBotSortActivityAt: Ref<string | null>;
  chatBlockCount: Ref<number>;
  chatToolCount: Ref<number>;
  llmConfigurations: Ref<LlmConfiguration[]>;
  artifactToolsAvailable: Ref<boolean>;
  activeGenerationId: Ref<number | null>;
  menuOpen: Ref<boolean>;
  deleting: Ref<boolean>;
  toggleMenu: () => void;
  closeMenu: () => void;
  stackOpen: (payload: { path: string; query?: Record<string, string> }) => void;
  pushRoute: (path: string, query?: Record<string, string>) => Promise<unknown>;
  reloadChat: () => Promise<void>;
  refreshPromptContext: () => Promise<void>;
};

type ChatBotOption = {
  id: ChatBotOptionId;
  name: string;
  image?: Bot['image'];
  shared_incoming?: Bot['shared_incoming'];
  shared_outgoing?: Bot['shared_outgoing'];
  created_at?: string | null;
  updated_at?: string | null;
  sort_activity_at?: string | null;
  pinned?: boolean;
};

const SAME_CHAT_OPTION_ID = 'same_chat' as const;
type SameChatOptionId = typeof SAME_CHAT_OPTION_ID;
type ChatBotOptionId = number | '' | SameChatOptionId;

export function useChatHeaderControls(params: Params) {
  const selectedConfig = ref<number | ''>('');
  const configSyncStatus = ref<'synced' | 'pending' | 'error'>('synced');
  const configSyncError = ref('');
  let configSyncToken = 0;
  let resolveConfigSync: (() => void) | null = null;
  let configSyncPromise: Promise<void> = Promise.resolve();

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
    const prefix = cfg.shared_incoming ? '⇣ ' : cfg.shared_outgoing ? '⇡ ' : '';
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
  const chatBaseTitle = computed(() =>
    formatChatBaseTitle({
      botName: currentBotName.value,
      note: params.chatNote.value,
    })
  );
  const chatFullTitle = computed(() =>
    formatChatFullTitle({
      botName: currentBotName.value,
      note: params.chatNote.value,
    })
  );
  const currentBotCompatibleTagIds = computed(() =>
    normalizeIdList(currentBotInfo.value?.compatible_configuration_tag_ids || [])
  );
  const currentBotCompatibleTagNames = computed(() =>
    normalizeNameList(currentBotInfo.value?.compatible_configuration_tag_names || [])
  );
  const currentBotDefaultConfigurationId = computed(() => {
    const id = currentBotInfo.value?.default_llm_configuration_id;
    return typeof id === 'number' && Number.isFinite(id) && id > 0 ? id : null;
  });
  const defaultConfig = computed(() => {
    const id = currentBotDefaultConfigurationId.value;
    if (!id) return null;
    return (params.llmConfigurations.value || []).find((config) => config.id === id) || null;
  });
  const configMatchesBotFilter = (cfg: LlmConfiguration) => {
    if (
      !currentBotId.value ||
      (!currentBotCompatibleTagIds.value.length && !currentBotCompatibleTagNames.value.length)
    ) {
      return true;
    }

    const configTagIds = normalizeIdList(cfg.tag_ids || []);
    const configTagNames = normalizeNameList(cfg.tag_names || []);

    return (
      configTagIds.some((tagId) => currentBotCompatibleTagIds.value.includes(tagId)) ||
      configTagNames.some((tagName) => currentBotCompatibleTagNames.value.includes(tagName))
    );
  };
  const regularSelectableConfigs = computed(() =>
    (params.llmConfigurations.value || []).filter(
      (config) => config.enabled && configMatchesBotFilter(config) && config.id !== currentBotDefaultConfigurationId.value
    )
  );
  const selectableConfigs = computed(() => {
    const defaultConfiguration = defaultConfig.value;
    if (!defaultConfiguration) return regularSelectableConfigs.value;
    return [defaultConfiguration, ...regularSelectableConfigs.value];
  });
  const moreConfigs = computed(() => {
    const selectableIds = new Set(selectableConfigs.value.map((config) => config.id));
    return (params.llmConfigurations.value || []).filter((config) => !selectableIds.has(config.id));
  });
  const fileUploadPolicy = computed(() =>
    resolveChatUploadPolicy(currentBotInfo.value, currentConfig.value, params.artifactToolsAvailable.value)
  );
  const selectedDisabledConfigReason = computed<'disabled' | 'incompatible' | null>(() => {
    if (!selectedConfig.value) return null;

    const selected = (params.llmConfigurations.value || []).find((config) => config.id === Number(selectedConfig.value));
    if (!selected) return null;
    if (selectableConfigs.value.some((config) => config.id === selected.id)) return null;
    if (moreConfigs.value.some((config) => config.id === selected.id)) return null;
    if (!selected.enabled) return 'disabled';
    return 'incompatible';
  });
  const selectedDisabledConfig = computed(() => {
    if (!selectedConfig.value || !selectedDisabledConfigReason.value) return null;
    return (params.llmConfigurations.value || []).find((config) => config.id === Number(selectedConfig.value)) || null;
  });

  const canAttachFiles = computed(() => params.canEdit.value && fileUploadPolicy.value.allowsFiles);
  const fileInputAccept = computed(() => fileUploadPolicy.value.accept);
  const fileAttachTitle = computed(() => describeChatUploadPolicy(fileUploadPolicy.value));
  const fileDropHint = computed(() =>
    fileUploadPolicy.value.imagesOnly ? 'Drop images here to attach them' : 'Drop files here to attach them'
  );

  const beginConfigSync = () => {
    configSyncPromise = new Promise<void>((resolve) => {
      resolveConfigSync = resolve;
    });
  };

  const finishConfigSync = () => {
    resolveConfigSync?.();
    resolveConfigSync = null;
  };

  const waitForConfigSync = async (timeoutMs = CONFIG_SYNC_GRACE_PERIOD_MS) => {
    if (!isConfigSyncPending.value) return true;

    let timeoutHandle = 0;

    try {
      const timeoutPromise = new Promise<boolean>((resolve) => {
        timeoutHandle = window.setTimeout(() => {
          resolve(!isConfigSyncPending.value);
        }, timeoutMs);
      });

      return await Promise.race([
        configSyncPromise.then(() => true),
        timeoutPromise,
      ]);
    } finally {
      if (timeoutHandle) window.clearTimeout(timeoutHandle);
    }
  };

  const hydrate = (payload: {
    selectedConfig: number | '';
    missingRequiredPerUserToolAliases: string[];
  }) => {
    selectedConfig.value = payload.selectedConfig;
    configSyncStatus.value = 'synced';
    configSyncError.value = '';
    finishConfigSync();
    missingRequiredPerUserToolAliases.value = payload.missingRequiredPerUserToolAliases || [];
    showMissingToolsBanner.value = missingRequiredPerUserToolAliases.value.length > 0;
  };

  const noteModalOpen = ref(false);
  const noteModalValue = ref('');
  const savingNote = ref(false);

  const openNoteModal = () => {
    if (!params.canEdit.value) return;
    noteModalValue.value = params.chatNote.value || '';
    noteModalOpen.value = true;
  };

  const closeNoteModal = () => {
    noteModalOpen.value = false;
  };

  const saveNote = async () => {
    if (!params.canEdit.value) return;
    if (!params.chatId.value || savingNote.value) return;
    savingNote.value = true;
    try {
      const nextNote = noteModalValue.value.trim();
      await api.patch(`/api/bff/chat-lifecycle/${params.chatId.value}`, { note: nextNote });
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
  const creatingChat = ref(false);
  const newChatModalOpen = ref(false);
  const newChatBotValue = ref<ChatBotOptionId>(SAME_CHAT_OPTION_ID);
  const noBotSortActivityAt = computed(() => {
    if (params.noBotSortActivityAt.value) return params.noBotSortActivityAt.value;
    if (params.chat.value?.bot_id != null) return null;
    return params.chat.value?.updated_at ?? params.chat.value?.created_at ?? null;
  });
  const countLabel = (count: number, singular: string, plural: string) => `${count} ${count === 1 ? singular : plural}`;
  const sameChatContextLabel = computed(() => {
    const blockCount = Math.max(0, Number(params.chatBlockCount.value) || 0);
    const toolCount = Math.max(0, Number(params.chatToolCount.value) || 0);
    const parts = [
      blockCount > 0 ? countLabel(blockCount, 'block', 'blocks') : '',
      toolCount > 0 ? countLabel(toolCount, 'tool', 'tools') : '',
    ].filter(Boolean);

    return parts.length ? ` (${parts.join(', ')})` : '';
  });
  const sameChatOptionName = computed(() => `⧉ ${currentBotName.value || 'No bot'}${sameChatContextLabel.value}`);

  const botSelectionOptions = computed<ChatBotOption[]>(() => [
    {
      id: '',
      name: 'No bot',
      sort_activity_at: noBotSortActivityAt.value,
      updated_at: noBotSortActivityAt.value,
      created_at: noBotSortActivityAt.value,
    },
    ...(params.bots.value || []).map((bot) => ({
      id: bot.id,
      name: bot.name,
      image: bot.image ?? null,
      shared_incoming: bot.shared_incoming,
      shared_outgoing: bot.shared_outgoing,
      created_at: bot.created_at ?? null,
      updated_at: bot.updated_at ?? null,
      sort_activity_at: bot.sort_activity_at ?? null,
    })),
  ]);

  const createChatBotOptions = computed<ChatBotOption[]>(() => [
    {
      id: SAME_CHAT_OPTION_ID,
      name: sameChatOptionName.value,
      pinned: true,
    },
    ...botSelectionOptions.value,
  ]);

  const openBotModal = () => {
    if (!params.canEdit.value) return;
    botModalValue.value = params.chat.value?.bot_id ?? '';
    botModalOpen.value = true;
  };

  const closeBotModal = () => {
    botModalOpen.value = false;
  };

  const saveBotSelection = async () => {
    if (!params.canEdit.value) return;
    if (!params.chatId.value || savingBot.value) return;
    savingBot.value = true;
    try {
      const botId = botModalValue.value === '' ? null : Number(botModalValue.value);
      await api.patch(`/api/bff/chat-lifecycle/${params.chatId.value}`, { bot_id: botId });
      await params.reloadChat();
      closeBotModal();
    } catch (error) {
      console.error(error);
      window.alert('Failed to update bot.');
    } finally {
      savingBot.value = false;
    }
  };

  const openNewChatModal = () => {
    if (creatingChat.value) return;
    newChatBotValue.value = SAME_CHAT_OPTION_ID;
    newChatModalOpen.value = true;
  };

  const closeNewChatModal = () => {
    if (creatingChat.value) return;
    newChatModalOpen.value = false;
  };

  const createChat = async (selectedBotId: number | string | '' = newChatBotValue.value) => {
    if (creatingChat.value) return;
    creatingChat.value = true;
    try {
      const botId = selectedBotId === '' ? null : Number(selectedBotId);
      const requestPayload =
        selectedBotId === SAME_CHAT_OPTION_ID
          ? { copy_from_chat_id: params.chatId.value }
          : {
              bot_id:
                typeof botId === 'number' && Number.isInteger(botId) && botId > 0 ? botId : null,
            };

      const payload = await api.post<{ chat: { id: number } }>('/api/bff/chat-lifecycle', requestPayload);
      const id = payload.chat?.id;
      if (!id) throw new Error('Missing chat id');
      newChatModalOpen.value = false;
      await params.pushRoute(`/chats/${id}`, { focusComposer: '1' });
    } finally {
      creatingChat.value = false;
    }
  };

  const updateConfig = async () => {
    if (!params.canEdit.value) return;
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
    beginConfigSync();

    const cfgId = selectedConfig.value === '' ? null : Number(selectedConfig.value);

    try {
      const payload = await api.patch<{ chat: Chat }>(`/api/bff/chat-lifecycle/${params.chatId.value}`, {
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
    } finally {
      if (configSyncToken === token) finishConfigSync();
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
    if (!params.canEdit.value) return;
    window.alert('Not implemented yet.');
    params.closeMenu();
  };

  const dismissMissingToolsBanner = () => {
    showMissingToolsBanner.value = false;
  };

  const removeChat = async () => {
    if (!params.canEdit.value) return;
    if (!params.chatId.value || params.deleting.value) return;
    const ok = window.confirm('Delete this chat? All messages will be removed.');
    if (!ok) {
      params.closeMenu();
      return;
    }
    params.deleting.value = true;
    try {
      await api.del(`/api/bff/chat-lifecycle/${params.chatId.value}`);
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
    waitForConfigSync,
    currentConfig,
    configLabel,
    messageConfigLabel,
    editConfigLabel,
    currentBotId,
    currentBotInfo,
    currentBotName,
    chatBaseTitle,
    chatFullTitle,
    fileUploadPolicy,
    selectableConfigs,
    defaultConfig,
    regularSelectableConfigs,
    moreConfigs,
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
    creatingChat,
    newChatModalOpen,
    newChatBotValue,
    botSelectionOptions,
    createChatBotOptions,
    openNewChatModal,
    closeNewChatModal,
    createChat,
    updateConfig,
    openConfigEditor,
    openBotEditor,
    openBotTools,
    dismissMissingToolsBanner,
    removeChat,
  };
}
