import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch, type Ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';

import { api, getApiErrorMessage, isHttpError } from '@/api/client';
import { jsonApiList, toIntId } from '@/api/jsonApi';
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
  overallPendingUploadProgress,
  resolveChatUploadPolicy,
  validateFilesForChatUpload,
  type ExistingChatAttachment,
  type PendingChatFile,
} from '@/features/chat/attachments';
import {
  abortChatUploadSession,
  createChatUploadSession,
  getChatUploadSession,
  uploadChatChunk,
  UploadAbortedError,
  type ChatUploadInfo,
} from '@/features/chat/upload';
import { copyTextWithFallback } from '@/utils/clipboard';
import { displayTimestampIso, formatRelativeDateTime } from '@/utils/dates';
import type {
  Bot,
  Chat,
  ChatBranchMessage,
  ChatMessageContent,
  ChatKnowledgeBlock,
  ChatToolBinding,
  ChatMessageStep,
  ChatVariable,
  KnowledgeBlock,
  LlmConfiguration,
  ToolInstanceOption,
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
  chat_tool_bindings: ChatToolBinding[];
  prompt_sources: {
    bot: PromptBinding[];
    chat: PromptBinding[];
    configuration: PromptBinding[];
    user: PromptBinding[];
  };
  compiled_prompt_text: string | null;
  counters: Counters;
  active_tool_instances: ActiveToolInstance[];
  missing_required_per_user_tool_aliases: string[];
  options: {
    bots: Bot[];
    llm_configurations: LlmConfiguration[];
    knowledge_blocks: KnowledgeBlock[];
    tool_instances: ToolInstanceOption[];
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

type ChatToolBindingLink = {
  id: number;
  alias: string;
  enabled: boolean;
  sequence: number;
  tool_instance_id: number;
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

const normalizeChatToolsForCompare = (bindings: ChatToolBindingLink[]) => {
  return [...(bindings || [])]
    .map((binding) => ({
      alias: normalizeText(binding.alias),
      tool_instance_id: Number(binding.tool_instance_id) || 0,
      enabled: Boolean(binding.enabled),
      sequence: Number(binding.sequence) || 0,
    }))
    .sort((a, b) => a.sequence - b.sequence || a.alias.localeCompare(b.alias) || a.tool_instance_id - b.tool_instance_id);
};

const normalizeIdList = (ids: number[] | null | undefined) =>
  Array.from(new Set((ids || []).filter((id): id is number => typeof id === 'number' && id > 0))).sort((a, b) => a - b);

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

  const findPendingFile = (filesRef: Ref<PendingChatFile[]>, id: string) =>
    filesRef.value.find((item) => item.id === id) || null;

  const updatePendingFile = (
    filesRef: Ref<PendingChatFile[]>,
    id: string,
    updater: Partial<PendingChatFile> | ((current: PendingChatFile) => Partial<PendingChatFile>)
  ) => {
    let nextItem: PendingChatFile | null = null;

    filesRef.value = filesRef.value.map((item) => {
      if (item.id !== id) return item;
      const patch = typeof updater === 'function' ? updater(item) : updater;
      nextItem = { ...item, ...patch };
      return nextItem;
    });

    return nextItem;
  };

  const syncPendingFileWithUpload = (
    filesRef: Ref<PendingChatFile[]>,
    id: string,
    upload: ChatUploadInfo,
    extra: Partial<PendingChatFile> = {}
  ) =>
    updatePendingFile(filesRef, id, (current) => {
      const uploadedBytes = Math.min(upload.uploaded_bytes || 0, current.size);
      const uploadStatus =
        upload.status === 'uploaded'
          ? 'uploaded'
          : upload.status === 'uploading'
            ? 'uploading'
            : 'error';

      return {
        uploadId: upload.upload_id,
        uploadStatus,
        uploadedBytes,
        progress: current.size > 0 ? uploadedBytes / current.size : 1,
        ...(uploadStatus === 'uploaded'
          ? { speedBps: 0, etaSeconds: 0, abortHandle: null }
          : {}),
        ...extra,
      };
    });

  const resolveChatUpload = async (chatIdValue: number, file: PendingChatFile) => {
    if (file.uploadId) {
      try {
        const upload = await getChatUploadSession(chatIdValue, file.uploadId);
        if (upload.status === 'uploading' || upload.status === 'uploaded') {
          return upload;
        }
      } catch (error) {
        if (!isHttpError(error) || error.status !== 404) throw error;
      }
    }

    return createChatUploadSession(chatIdValue, file.file);
  };

  const uploadPendingFile = async (
    filesRef: Ref<PendingChatFile[]>,
    fileId: string,
    chatIdValue: number
  ) => {
    const pending = findPendingFile(filesRef, fileId);
    if (!pending) return null;

    let upload = await resolveChatUpload(chatIdValue, pending);
    let offset = Math.min(upload.uploaded_bytes || 0, pending.size);

    if (upload.status !== 'uploading' && upload.status !== 'uploaded') {
      upload = await createChatUploadSession(chatIdValue, pending.file);
      offset = 0;
    }

    syncPendingFileWithUpload(filesRef, fileId, upload, {
      error: '',
      speedBps: 0,
      etaSeconds: offset >= pending.size ? 0 : null,
    });

    if (upload.status === 'uploaded' || offset >= pending.size) {
      syncPendingFileWithUpload(filesRef, fileId, upload, {
        uploadStatus: 'uploaded',
        uploadedBytes: pending.size,
        progress: 1,
        speedBps: 0,
        etaSeconds: 0,
        abortHandle: null,
        error: '',
      });
      return upload.upload_id;
    }

    let resumeOffset = offset;
    let startedAt = performance.now();

    while (offset < pending.size) {
      const liveFile = findPendingFile(filesRef, fileId);
      if (!liveFile) return null;

      const chunkSize = Math.min(upload.chunk_size_bytes || liveFile.size, liveFile.size - offset);
      const chunk = liveFile.file.slice(offset, offset + chunkSize);

      try {
        upload = await uploadChatChunk(chatIdValue, upload.upload_id, offset, chunk, {
          onAbortHandle: (abortHandle) => {
            updatePendingFile(filesRef, fileId, { abortHandle });
          },
          onProgress: (loadedBytes) => {
            const currentFile = findPendingFile(filesRef, fileId);
            if (!currentFile) return;

            const totalUploaded = Math.min(offset + loadedBytes, currentFile.size);
            const elapsedSeconds = Math.max((performance.now() - startedAt) / 1000, 0.001);
            const transferredBytes = Math.max(totalUploaded - resumeOffset, 0);
            const speedBps = transferredBytes / elapsedSeconds;
            const remainingBytes = Math.max(currentFile.size - totalUploaded, 0);

            updatePendingFile(filesRef, fileId, {
              uploadId: upload.upload_id,
              uploadStatus: 'uploading',
              uploadedBytes: totalUploaded,
              progress: currentFile.size > 0 ? totalUploaded / currentFile.size : 1,
              speedBps,
              etaSeconds: speedBps > 0 ? remainingBytes / speedBps : null,
              error: '',
            });
          },
        });

        const currentFile = findPendingFile(filesRef, fileId);
        if (!currentFile) return null;

        offset = Math.min(upload.uploaded_bytes || 0, currentFile.size);
        syncPendingFileWithUpload(filesRef, fileId, upload, {
          error: '',
          speedBps: offset >= currentFile.size ? 0 : currentFile.speedBps,
          etaSeconds: offset >= currentFile.size ? 0 : currentFile.etaSeconds,
          abortHandle: null,
        });
      } catch (error) {
        if (error instanceof UploadAbortedError) {
          const stillPresent = findPendingFile(filesRef, fileId);
          if (!stillPresent) return null;

          updatePendingFile(filesRef, fileId, {
            uploadStatus: 'error',
            abortHandle: null,
            speedBps: 0,
            etaSeconds: null,
            error: 'Upload aborted.',
          });

          throw error;
        }

        if (isHttpError(error) && error.status === 409) {
          const nextOffset = Number((error.bodyJson as { next_offset?: unknown } | null)?.next_offset);

          if (Number.isFinite(nextOffset) && nextOffset >= 0) {
            const currentFile = findPendingFile(filesRef, fileId);
            if (!currentFile) return null;

            offset = Math.min(nextOffset, currentFile.size);
            resumeOffset = offset;
            startedAt = performance.now();
            upload = await getChatUploadSession(chatIdValue, upload.upload_id);
            syncPendingFileWithUpload(filesRef, fileId, upload, {
              error: '',
              speedBps: 0,
              etaSeconds: null,
              abortHandle: null,
            });
            continue;
          }
        }

        updatePendingFile(filesRef, fileId, {
          uploadStatus: 'error',
          abortHandle: null,
          speedBps: 0,
          etaSeconds: null,
          error: errorMessage(error, 'Failed to upload attachment.'),
        });

        throw error;
      }
    }

    const finalFile = findPendingFile(filesRef, fileId);
    if (!finalFile) return null;

    updatePendingFile(filesRef, fileId, {
      uploadId: upload.upload_id,
      uploadStatus: 'uploaded',
      uploadedBytes: finalFile.size,
      progress: 1,
      speedBps: 0,
      etaSeconds: 0,
      abortHandle: null,
      error: '',
    });

    return upload.upload_id;
  };

  const ensurePendingFilesUploaded = async (filesRef: Ref<PendingChatFile[]>) => {
    if (!chatId.value) return [];

    let index = 0;

    while (index < filesRef.value.length) {
      const item = filesRef.value[index];
      if (!item) break;

      if (item.uploadStatus === 'uploaded' && item.uploadId) {
        index += 1;
        continue;
      }

      try {
        await uploadPendingFile(filesRef, item.id, chatId.value);
      } catch (error) {
        if (error instanceof UploadAbortedError && !findPendingFile(filesRef, item.id)) {
          continue;
        }

        throw error;
      }

      const updated = findPendingFile(filesRef, item.id);
      if (!updated) continue;
      if (updated.uploadStatus === 'uploaded' && updated.uploadId) {
        index += 1;
        continue;
      }

      throw new Error(updated.error || 'Failed to upload attachment.');
    }

    return filesRef.value
      .map((item) => item.uploadId)
      .filter((value): value is string => typeof value === 'string' && value.trim() !== '');
  };

  const removePendingFileFromCollection = async (filesRef: Ref<PendingChatFile[]>, id: string) => {
    const current = findPendingFile(filesRef, id);
    if (!current) return;

    current.abortHandle?.();
    filesRef.value = filesRef.value.filter((item) => item.id !== id);

    if (!chatId.value || !current.uploadId) return;

    try {
      await abortChatUploadSession(chatId.value, current.uploadId);
    } catch (error) {
      if (!isHttpError(error) || error.status !== 404) {
        console.warn('Failed to abort chat upload session', error);
      }
    }
  };

  const clearPendingFilesCollection = async (filesRef: Ref<PendingChatFile[]>) => {
    const snapshot = [...filesRef.value];
    filesRef.value = [];

    for (const item of snapshot) {
      item.abortHandle?.();

      if (!chatId.value || !item.uploadId) continue;

      try {
        await abortChatUploadSession(chatId.value, item.uploadId);
      } catch (error) {
        if (!isHttpError(error) || error.status !== 404) {
          console.warn('Failed to abort chat upload session', error);
        }
      }
    }
  };

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

  const errorMessage = (error: unknown, fallback: string) => getApiErrorMessage(error, fallback);

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
  const sendButtonLabel = computed(() => {
    if (activeGenerationId.value) {
      return cancelingGenerationId.value === activeGenerationId.value ? 'Cancelling…' : 'Cancel';
    }

    if (sending.value) {
      const uploadProgress = overallPendingUploadProgress(pendingFiles.value);
      if (uploadProgress.active) {
        return `Uploading… ${Math.max(1, Math.round(uploadProgress.progress * 100))}%`;
      }

      return 'Sending…';
    }

    return 'Send';
  });

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
      const uploadIds = pendingFiles.value.length > 0 ? await ensurePendingFilesUploaded(pendingFiles) : [];
      const hasPendingFiles = uploadIds.length > 0;

      const payload =
        hasUserText || hasPendingFiles
          ? await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
              `/api/bff/chats/${chatId.value}/send`,
              buildSendPayload(content, uploadIds)
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
    void removePendingFileFromCollection(pendingFiles, id);
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
  const editSaveLabel = computed(() => {
    if (!savingEdit.value) return modalMode.value === 'branch' ? 'Branch' : 'Save';

    const uploadProgress = overallPendingUploadProgress(editPendingFiles.value);
    if (uploadProgress.active) {
      return `Uploading… ${Math.max(1, Math.round(uploadProgress.progress * 100))}%`;
    }

    return modalMode.value === 'branch' ? 'Branching…' : 'Saving…';
  });

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
    void clearPendingFilesCollection(editPendingFiles);
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
      void clearPendingFilesCollection(editPendingFiles);
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

  const resetEditState = () => {
    editingMessage.value = null;
    editContentIds.value = [];
    editContents.value = [];
    editExistingAttachments.value = [];
    editRemovedAttachmentIds.value = [];
    editPendingFiles.value = [];
    editError.value = '';
  };

  const cancelEdit = () => {
    void clearPendingFilesCollection(editPendingFiles);
    resetEditState();
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
    void removePendingFileFromCollection(editPendingFiles, id);
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
        const uploadIds =
          editPendingFiles.value.length > 0 ? await ensurePendingFilesUploaded(editPendingFiles) : [];

        const updatePayload = buildMessageUpdatePayload(
          hasTextUpdates ? updates : null,
          editRemovedAttachmentIds.value,
          uploadIds
        );

        const payload = await api.patch<{ branch: ChatBranchMessage[] }>(
          `/api/bff/chat-messages/${editingMessage.value.id}`,
          updatePayload
        );
        branch.value = payload.branch || [];
        resetEditState();
      } else {
        if (isConfigSyncPending.value) {
          alert('Configuration change is still syncing. Please wait before starting a new generation.');
          return;
        }
        const parentId = editingMessage.value.parent_id ?? null;
        const uploadIds =
          editPendingFiles.value.length > 0 ? await ensurePendingFilesUploaded(editPendingFiles) : [];
        const hasBranchFiles = editExistingAttachments.value.length > 0 || uploadIds.length > 0;
        const payload = await api.post<{ branch: ChatBranchMessage[]; generation: { message_id: number } }>(
          `/api/bff/chats/${chatId.value}/send`,
          hasBranchFiles
            ? buildSendPayload(
                editContents.value[0] ?? '',
                uploadIds,
                editExistingAttachments.value,
                parentId
              )
            : { content: editContents.value[0] ?? '', parent_id: parentId }
        );
        branch.value = payload.branch || [];
        resetEditState();

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
  let attachmentPreviewObjectUrl: string | null = null;

  const revokeAttachmentPreviewObjectUrl = () => {
    if (!attachmentPreviewObjectUrl) return;
    URL.revokeObjectURL(attachmentPreviewObjectUrl);
    attachmentPreviewObjectUrl = null;
  };

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

    revokeAttachmentPreviewObjectUrl();
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

  const openPendingAttachmentPreview = async (fileId: string) => {
    const pending = findPendingFile(pendingFiles, fileId) || findPendingFile(editPendingFiles, fileId);
    if (!pending) return;

    const isImage = pending.mimeType.trim().toLowerCase().startsWith('image/');
    const kind = getAttachmentPreviewKind(pending.name, pending.mimeType, isImage);
    const objectUrl = URL.createObjectURL(pending.file);
    const token = attachmentPreviewRequestToken.value + 1;

    attachmentPreviewRequestToken.value = token;
    revokeAttachmentPreviewObjectUrl();
    attachmentPreviewObjectUrl = objectUrl;
    attachmentPreviewOpen.value = true;
    attachmentPreviewTitle.value = pending.name;
    attachmentPreviewUrl.value = objectUrl;
    attachmentPreviewKind.value = kind;
    attachmentPreviewLoading.value = kind !== 'image' && kind !== 'binary';
    attachmentPreviewError.value = '';
    attachmentPreviewText.value = '';

    if (kind === 'image' || kind === 'binary') {
      attachmentPreviewLoading.value = false;
      return;
    }

    try {
      const text = await pending.file.text();
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

  const openExistingAttachmentPreview = async (attachment: ExistingChatAttachment) => {
    await openAttachmentPreview({
      messageId: attachment.messageId,
      content: attachment.content,
    });
  };

  const closeAttachmentPreview = () => {
    revokeAttachmentPreviewObjectUrl();
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
  const chatToolBindingsOriginal = ref<ChatToolBindingLink[]>([]);
  const chatToolBindingsDraft = ref<ChatToolBindingLink[]>([]);
  let tempChatToolBindingId = -1;

  const toChatBlockLinks = (bindings: ChatKnowledgeBlock[]) =>
    (bindings || []).map((b) => ({
      id: b.id,
      block: b.knowledge_block_id,
      enabled: Boolean(b.enabled),
      sequence: Number(b.sequence) || 0,
    }));

  const toChatToolBindingLinks = (bindings: ChatToolBinding[]) =>
    (bindings || []).map((binding) => ({
      id: binding.id,
      alias: String(binding.alias || '').trim(),
      tool_instance_id: Number(binding.tool_instance_id) || 0,
      enabled: Boolean(binding.enabled),
      sequence: Number(binding.sequence) || 0,
    }));

  const normalizeSequences = (items: ChatBlockLink[]) => {
    return [...items].map((item, idx) => ({ ...item, sequence: idx }));
  };

  const normalizeToolSequences = (items: ChatToolBindingLink[]) => {
    return [...items].map((item, idx) => ({ ...item, sequence: idx }));
  };

  const chatBlocks = computed(() => chatBlocksDraft.value);
  const chatToolBindings = computed(() => chatToolBindingsDraft.value);

  const chatVariablesOriginal = ref<Partial<ChatVariable>[]>([]);
  const chatVariables = ref<Partial<ChatVariable>[]>([]);
  const toolLibrary = ref<ToolInstanceOption[]>([]);

  const toolLibraryById = computed(() => {
    const map = new Map<number, ToolInstanceOption>();
    for (const tool of toolLibrary.value || []) {
      if (typeof tool.id === 'number') {
        map.set(tool.id, tool);
      }
    }
    return map;
  });

  const chatTabDirty = computed(() => {
    const varsA = normalizeVariablesForCompare(chatVariablesOriginal.value);
    const varsB = normalizeVariablesForCompare(chatVariables.value);
    const blocksA = normalizeChatBlocksForCompare(chatBlocksOriginal.value);
    const blocksB = normalizeChatBlocksForCompare(chatBlocksDraft.value);
    const toolsA = normalizeChatToolsForCompare(chatToolBindingsOriginal.value);
    const toolsB = normalizeChatToolsForCompare(chatToolBindingsDraft.value);

    return (
      jsonStable(varsA) !== jsonStable(varsB) ||
      jsonStable(blocksA) !== jsonStable(blocksB) ||
      jsonStable(toolsA) !== jsonStable(toolsB)
    );
  });

  const savingChatChanges = ref(false);
  const newChatToolInstanceId = ref(0);
  const newChatToolAlias = ref('');

  const cancelChatChanges = () => {
    chatVariables.value = [...chatVariablesOriginal.value];
    chatBlocksDraft.value = [...chatBlocksOriginal.value];
    chatToolBindingsDraft.value = [...chatToolBindingsOriginal.value];
    newChatToolInstanceId.value = 0;
    newChatToolAlias.value = '';
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
        tool_bindings: (chatToolBindingsDraft.value || []).map((binding) => ({
          ...(binding.id > 0 ? { id: binding.id } : {}),
          tool_instance_id: binding.tool_instance_id,
          alias: String(binding.alias || '').trim(),
          enabled: Boolean(binding.enabled),
        })),
      });

      await loadChat({ mode: 'soft' });
    } catch (error) {
      console.error(error);
      alert(error instanceof Error ? error.message : 'Failed to save chat changes.');
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

  const toolLabel = (toolInstanceId: number) => {
    const tool = toolLibraryById.value.get(toolInstanceId);
    if (!tool) return `Tool #${toolInstanceId}`;
    return `${tool.name} (${tool.type})`;
  };

  const toolTypeLabel = (toolInstanceId: number) => {
    return toolLibraryById.value.get(toolInstanceId)?.type || 'Tool';
  };

  const toolIsOutlet = (toolInstanceId: number) => toolLibraryById.value.get(toolInstanceId)?.type === 'outlet';

  const toolIsOnline = (toolInstanceId: number) => Boolean(toolLibraryById.value.get(toolInstanceId)?.outlet_online);

  const addChatToolBinding = () => {
    const toolInstanceId = Number(newChatToolInstanceId.value || 0);
    const alias = String(newChatToolAlias.value || '').trim();

    if (!toolInstanceId) {
      alert('Choose a tool.');
      return;
    }

    if (!alias) {
      alert('Alias is required.');
      return;
    }

    if (alias.includes('__')) {
      alert('Alias must not contain "__".');
      return;
    }

    if (!/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(alias)) {
      alert('Alias must start with a letter and contain only letters, numbers, "_" or "-".');
      return;
    }

    if (chatToolBindingsDraft.value.some((binding) => binding.alias === alias)) {
      alert('Alias is already used in this chat.');
      return;
    }

    const next = normalizeToolSequences(chatToolBindingsDraft.value);
    chatToolBindingsDraft.value = normalizeToolSequences([
      ...next,
      {
        id: tempChatToolBindingId--,
        alias,
        tool_instance_id: toolInstanceId,
        enabled: true,
        sequence: next.length,
      },
    ]);

    newChatToolInstanceId.value = 0;
    newChatToolAlias.value = '';
  };

  const moveChatToolBinding = (binding: ChatToolBindingLink, delta: number) => {
    const idx = chatToolBindingsDraft.value.findIndex((row) => row.id === binding.id);
    if (idx === -1) return;
    const nextIndex = idx + delta;
    if (nextIndex < 0 || nextIndex >= chatToolBindingsDraft.value.length) return;
    const next = [...chatToolBindingsDraft.value];
    const current = next[idx];
    next[idx] = next[nextIndex];
    next[nextIndex] = current;
    chatToolBindingsDraft.value = normalizeToolSequences(next);
  };

  const removeChatToolBinding = (bindingId: number) => {
    chatToolBindingsDraft.value = normalizeToolSequences(
      chatToolBindingsDraft.value.filter((binding) => binding.id !== bindingId)
    );
  };

  const setChatToolBindingEnabled = (bindingId: number, enabled: boolean) => {
    chatToolBindingsDraft.value = chatToolBindingsDraft.value.map((binding) =>
      binding.id === bindingId ? { ...binding, enabled } : binding
    );
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
    toolLibrary.value = payload.options?.tool_instances || [];

    selectedConfig.value = payload.chat?.llm_configuration_id ?? '';
    configSyncStatus.value = 'synced';
    configSyncError.value = '';

    chatBlocksOriginal.value = normalizeSequences(toChatBlockLinks(payload.chat_blocks || []));
    chatBlocksDraft.value = [...chatBlocksOriginal.value];
    chatToolBindingsOriginal.value = normalizeToolSequences(toChatToolBindingLinks(payload.chat_tool_bindings || []));
    chatToolBindingsDraft.value = [...chatToolBindingsOriginal.value];
    newChatToolInstanceId.value = 0;
    newChatToolAlias.value = '';

    chatVariablesOriginal.value = payload.chat?.variables || [];
    chatVariables.value = [...chatVariablesOriginal.value];
    activeToolInstances.value = payload.active_tool_instances || [];
    missingRequiredPerUserToolAliases.value = payload.missing_required_per_user_tool_aliases || [];
    showMissingToolsBanner.value = missingRequiredPerUserToolAliases.value.length > 0;
    botToolsLoading.value = false;
    botToolsError.value = '';

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
    void clearPendingFilesCollection(pendingFiles);
    void clearPendingFilesCollection(editPendingFiles);
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
    sendButtonLabel,
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
    editSaveLabel,
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
    openPendingAttachmentPreview,
    openExistingAttachmentPreview,
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
    chatToolBindings,
    chatVariables,
    toolLibrary,
    newChatToolInstanceId,
    newChatToolAlias,
    chatBlockName,
    chatBlockImage,
    chatBlockMeta,
    toolLabel,
    toolTypeLabel,
    toolIsOutlet,
    toolIsOnline,
    saveChatChanges,
    cancelChatChanges,
    openChatBlocksPicker,
    openNewBlock,
    openChatBlockEditor,
    addChatToolBinding,
    moveChatBlock,
    moveChatToolBinding,
    removeChatBlock,
    removeChatToolBinding,
    setChatToolBindingEnabled,
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

const buildSendPayload = (
  content: string,
  uploadIds: string[],
  existingAttachments: ExistingChatAttachment[] = [],
  parentId?: number | null
) => ({
  content,
  ...(parentId === null ? { parent_id: '' } : typeof parentId === 'number' ? { parent_id: parentId } : {}),
  ...(uploadIds.length > 0 ? { upload_ids: uploadIds } : {}),
  ...(existingAttachments.length > 0
    ? { copy_content_ids: existingAttachments.map((attachment) => attachment.id) }
    : {}),
});

const buildMessageUpdatePayload = (
  contents: Array<{ id: number; content_text: string }> | null,
  removeContentIds: number[],
  uploadIds: string[]
) => ({
  ...(contents && contents.length > 0 ? { contents } : {}),
  ...(removeContentIds.length > 0 ? { remove_content_ids: removeContentIds } : {}),
  ...(uploadIds.length > 0 ? { upload_ids: uploadIds } : {}),
});
