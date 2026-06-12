import { computed, ref, type ComputedRef, type Ref } from 'vue';

import { api } from '@/api/client';
import { jsonApiList, toIntId } from '@/api/jsonApi';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import { useKnowledgeBlockNewDraft } from '@/features/catalogs/model/useKnowledgeBlockNewDraft';
import { parseImageAsset } from '@/features/media/image';
import {
  moveToolBindingInList,
  markShadowedToolBindings,
  normalizeToolBindingSequences,
  removeToolBindingFromList,
  setToolBindingEnabledInList,
  validateNewToolBinding,
} from '@/features/tools/model/toolBindings';
import { useToolInstanceLibrary } from '@/features/tools/model/toolInstances';
import type {
  ChatKnowledgeBlock,
  ChatToolBinding,
  ChatVariable,
  KnowledgeBlock,
  ToolInstanceOption,
} from '@/types/api';
import {
  ChatBlockLink,
  ChatToolBindingLink,
  jsonStable,
  normalizeChatBlocksForCompare,
  normalizeChatToolsForCompare,
  normalizeVariablesForCompare,
} from '@/features/chat/model/chatViewModel.shared';

type Params = {
  chatId: ComputedRef<number>;
  readOnly: ComputedRef<boolean>;
  knowledgeBlocks: Ref<KnowledgeBlock[]>;
  toolLibrary: Ref<ToolInstanceOption[]>;
  routeFullPath: () => string;
  stackOpen: (payload: { path: string; query?: Record<string, string> }) => void;
  reloadChat: () => Promise<void>;
};

type HydratePayload = {
  chatBlocks: ChatKnowledgeBlock[];
  chatToolBindings: ChatToolBinding[];
  chatVariables: Partial<ChatVariable>[];
};

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

const normalizeSequences = (items: ChatBlockLink[]) => [...items].map((item, idx) => ({ ...item, sequence: idx }));
const cloneChatBlocks = (items: ChatBlockLink[]) => (items || []).map((item) => ({ ...item }));
const cloneChatToolBindings = (items: ChatToolBindingLink[]) => (items || []).map((item) => ({ ...item }));
const cloneChatVariables = (items: ChatVariable[]) => (items || []).map((item) => ({ ...item }));
const normalizeChatVariables = (items: Partial<ChatVariable>[]): ChatVariable[] =>
  (items || []).map((item) => ({
    key: String(item.key ?? ''),
    value: String(item.value ?? ''),
  }));

const toOptionalInt = (value: unknown) => {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.trunc(value);
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return Math.trunc(parsed);
  }
  return null;
};

export function useChatLibraryDraft(params: Params) {
  const chatBlocksOriginal = ref<ChatBlockLink[]>([]);
  const chatBlocksDraft = ref<ChatBlockLink[]>([]);
  let tempChatBlockId = -1;

  const chatToolBindingsOriginal = ref<ChatToolBindingLink[]>([]);
  const chatToolBindingsDraft = ref<ChatToolBindingLink[]>([]);
  let tempChatToolBindingId = -1;

  const chatVariablesOriginal = ref<ChatVariable[]>([]);
  const chatVariables = ref<ChatVariable[]>([]);

  const savingChatChanges = ref(false);
  const newChatToolInstanceIds = ref<number[]>([]);

  const chatBlocksPickerOpen = ref(false);
  const chatBlocksPickerSelection = ref<number[]>([]);

  const chatBlocks = computed(() => chatBlocksDraft.value);
  const chatToolBindings = computed(() =>
    markShadowedToolBindings(chatToolBindingsDraft.value, 'Another enabled chat tool with this alias has priority.')
  );
  const linkedChatBlockIds = computed(() => chatBlocksDraft.value.map((b) => b.block));

  const toolInstanceLibrary = useToolInstanceLibrary(params.toolLibrary);

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

  const hydrate = ({ chatBlocks, chatToolBindings, chatVariables: variables }: HydratePayload) => {
    chatBlocksOriginal.value = normalizeSequences(toChatBlockLinks(chatBlocks || []));
    chatBlocksDraft.value = cloneChatBlocks(chatBlocksOriginal.value);
    chatToolBindingsOriginal.value = normalizeToolBindingSequences(toChatToolBindingLinks(chatToolBindings || []));
    chatToolBindingsDraft.value = cloneChatToolBindings(chatToolBindingsOriginal.value);
    chatVariablesOriginal.value = normalizeChatVariables(variables || []);
    chatVariables.value = cloneChatVariables(chatVariablesOriginal.value);
    newChatToolInstanceIds.value = [];
  };

  const cancelChatChanges = () => {
    if (params.readOnly.value) return;
    chatVariables.value = cloneChatVariables(chatVariablesOriginal.value);
    chatBlocksDraft.value = cloneChatBlocks(chatBlocksOriginal.value);
    chatToolBindingsDraft.value = cloneChatToolBindings(chatToolBindingsOriginal.value);
    newChatToolInstanceIds.value = [];
  };

  const saveChatChanges = async () => {
    if (params.readOnly.value) return;
    if (!params.chatId.value || savingChatChanges.value) return;
    savingChatChanges.value = true;

    try {
      await api.patch(`/api/bff/chats/${params.chatId.value}`, {
        variables: chatVariables.value,
        knowledge_block_bindings: (chatBlocksDraft.value || []).map((binding) => ({
          ...(binding.id > 0 ? { id: binding.id } : {}),
          knowledge_block_id: binding.block,
          enabled: Boolean(binding.enabled),
        })),
        tool_bindings: (chatToolBindingsDraft.value || []).map((binding) => ({
          ...(binding.id > 0 ? { id: binding.id } : {}),
          tool_instance_id: binding.tool_instance_id,
          enabled: Boolean(binding.enabled),
        })),
      });

      await params.reloadChat();
    } catch (error) {
      console.error(error);
      window.alert(error instanceof Error ? error.message : 'Failed to save chat changes.');
    } finally {
      savingChatChanges.value = false;
    }
  };

  const openChatBlocksPicker = () => {
    if (params.readOnly.value) return;
    chatBlocksPickerSelection.value = [];
    chatBlocksPickerOpen.value = true;
  };

  const openChatBlockEditor = (blockId: number) => {
    const ids = Array.from(
      new Set((chatBlocks.value || []).map((binding) => binding.block).filter((id): id is number => typeof id === 'number' && id > 0))
    );
    const returnTo = params.routeFullPath();
    const navKey = createRecordset(ids, { returnTo });
    params.stackOpen({ path: `/catalogs/knowledge-blocks/${blockId}`, query: { navKey, returnTo } });
  };

  const openChatToolEditor = (toolInstanceId: number) => {
    const ids = Array.from(
      new Set(
        (chatToolBindings.value || [])
          .map((binding) => binding.tool_instance_id)
          .filter((id): id is number => typeof id === 'number' && id > 0)
      )
    );
    const returnTo = params.routeFullPath();
    const navKey = createRecordset(ids, { returnTo });
    params.stackOpen({ path: `/catalogs/tools/${toolInstanceId}`, query: { navKey, returnTo } });
  };

  const moveChatBlock = (binding: ChatBlockLink, delta: number) => {
    if (params.readOnly.value) return;
    const idx = chatBlocksDraft.value.findIndex((item) => item.id === binding.id);
    if (idx === -1) return;
    const nextIndex = idx + delta;
    if (nextIndex < 0 || nextIndex >= chatBlocksDraft.value.length) return;
    const next = [...chatBlocksDraft.value];
    const current = next[idx];
    next[idx] = next[nextIndex];
    next[nextIndex] = current;
    chatBlocksDraft.value = normalizeSequences(next);
  };

  const removeChatBlock = (bindingId: number) => {
    if (params.readOnly.value) return;
    chatBlocksDraft.value = chatBlocksDraft.value.filter((binding) => binding.id !== bindingId);
  };

  const setChatBlockEnabled = (bindingId: number, enabled: boolean) => {
    if (params.readOnly.value) return;
    chatBlocksDraft.value = chatBlocksDraft.value.map((binding) =>
      binding.id === bindingId ? { ...binding, enabled } : binding
    );
  };

  const chatBlockName = (blockId: number) => {
    const block = (params.knowledgeBlocks.value || []).find((item) => item.id === blockId);
    return block?.name || `Block #${blockId}`;
  };

  const chatBlockImage = (blockId: number) => {
    const block = (params.knowledgeBlocks.value || []).find((item) => item.id === blockId);
    return block?.image || null;
  };

  const chatBlockMeta = (binding: ChatBlockLink) => {
    const block = (params.knowledgeBlocks.value || []).find((item) => item.id === binding.block);
    const tokens = block?.token_count ?? 0;
    return `${tokens} tokens`;
  };

  const addChatToolBinding = (toolInstanceIds?: number[]) => {
    if (params.readOnly.value) return false;
    const ids = Array.from(
      new Set((toolInstanceIds ?? newChatToolInstanceIds.value).map((id) => Number(id || 0)).filter(Boolean))
    );
    if (!ids.length) {
      window.alert('Choose a tool.');
      return false;
    }

    const next = normalizeToolBindingSequences(chatToolBindingsDraft.value);
    const added = [...next];

    for (const toolInstanceId of ids) {
      const alias = toolInstanceLibrary.toolLibraryById.value.get(toolInstanceId)?.alias || '';
      const validationError = validateNewToolBinding({
        toolInstanceId,
        alias,
        bindings: added,
        messages: {
          missingTool: 'Choose a tool.',
          duplicateTool: 'Tool is already linked to this chat.',
          duplicateAlias: 'Alias is already used in this chat.',
        },
      });

      if (validationError) {
        window.alert(validationError);
        return false;
      }

      added.push({
        id: tempChatToolBindingId--,
        alias,
        tool_instance_id: toolInstanceId,
        enabled: true,
        sequence: added.length,
      });
    }

    chatToolBindingsDraft.value = normalizeToolBindingSequences(added);
    newChatToolInstanceIds.value = [];
    return true;
  };

  const moveChatToolBinding = (binding: ChatToolBindingLink, delta: number) => {
    if (params.readOnly.value) return;
    chatToolBindingsDraft.value = moveToolBindingInList(chatToolBindingsDraft.value, binding.id, delta);
  };

  const removeChatToolBinding = (bindingId: number) => {
    if (params.readOnly.value) return;
    chatToolBindingsDraft.value = removeToolBindingFromList(chatToolBindingsDraft.value, bindingId);
  };

  const setChatToolBindingEnabled = (bindingId: number, enabled: boolean) => {
    if (params.readOnly.value) return;
    chatToolBindingsDraft.value = setToolBindingEnabledInList(chatToolBindingsDraft.value, bindingId, enabled);
  };

  const addVariableRow = () => {
    if (params.readOnly.value) return;
    chatVariables.value = [...chatVariables.value, { key: '', value: '' }];
  };

  const addChatBlocks = (blockIds: number[]) => {
    if (params.readOnly.value) return;
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
      qs.set('fields[knowledge-blocks]', 'name,version,token_count,image');
      const payload = await jsonApiList('/api/ash/knowledge-blocks', qs);
      const nextBlocks = (payload.data || [])
        .map((resource): KnowledgeBlock | null => {
          const id = toIntId(resource.id);
          if (!id) return null;
          const attrs = (resource.attributes || {}) as Record<string, unknown>;
          return {
            id,
            name: String(attrs.name || ''),
            image: parseImageAsset(attrs.image),
            version: typeof attrs.version === 'string' ? attrs.version : null,
            token_count: toOptionalInt(attrs.token_count),
          } satisfies KnowledgeBlock;
        })
        .filter((block): block is KnowledgeBlock => Boolean(block));
      params.knowledgeBlocks.value = nextBlocks;
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
    resetOn: () => params.chatId.value,
  });

  return {
    chatBlocks,
    chatToolBindings,
    chatVariables,
    chatTabDirty,
    savingChatChanges,
    newChatToolInstanceIds,
    chatBlocksPickerOpen,
    chatBlocksPickerSelection,
    linkedChatBlockIds,
    hydrate,
    consumePendingNewBlockContext: newBlockDraft.consumePendingNewBlockContext,
    cancelChatChanges,
    saveChatChanges,
    openChatBlocksPicker,
    openNewBlock: newBlockDraft.openNewBlock,
    openChatBlockEditor,
    openChatToolEditor,
    moveChatBlock,
    removeChatBlock,
    setChatBlockEnabled,
    chatBlockName,
    chatBlockImage,
    chatBlockMeta,
    toolLabel: toolInstanceLibrary.toolLabel,
    toolTypeLabel: toolInstanceLibrary.toolTypeLabel,
    toolIsOutlet: toolInstanceLibrary.toolIsOutlet,
    toolIsOnline: toolInstanceLibrary.toolIsOnline,
    addChatToolBinding,
    moveChatToolBinding,
    removeChatToolBinding,
    setChatToolBindingEnabled,
    addVariableRow,
    addChatBlocks,
  };
}
