import type {
  Chat,
  ChatBranchMessage,
  ChatKnowledgeBlock,
  ChatMessageStep,
  ChatToolBinding,
  ChatVariable,
  Bot,
  KnowledgeBlock,
  LlmConfiguration,
  ToolInstanceOption,
} from '@/types/api';
import type { ActiveToolInstance } from '@/features/chat/types';
import type { ExistingChatAttachment } from '@/features/chat/attachments';

export type Counters = {
  prompt_token_count: number;
  history_token_count: number;
  history_message_count: number;
  total_token_count: number;
};

export type PromptBinding = {
  id: number;
  enabled: boolean;
  sequence: number;
  knowledge_block: KnowledgeBlock | null;
};

export type ChatStatePayload = {
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

export type ChatPromptContextPayload = Pick<
  ChatStatePayload,
  'prompt_sources' | 'compiled_prompt_text' | 'counters'
>;

export type PollResponse = {
  message_id: number;
  runtime: boolean;
  status: string;
  current_step: ChatMessageStep | null;
  steps?: ChatMessageStep[] | null;
  finished_at?: string | null;
  token_count?: number | null;
  error_detail?: string | null;
};

export type ChatBlockLink = {
  id: number;
  block: number;
  enabled: boolean;
  sequence: number;
};

export type ChatToolBindingLink = {
  id: number;
  alias: string;
  enabled: boolean;
  sequence: number;
  tool_instance_id: number;
};

const normalizeText = (value: unknown) => String(value ?? '').trim();

export const jsonStable = (value: unknown) => {
  try {
    return JSON.stringify(value);
  } catch {
    return '';
  }
};

export const normalizeVariablesForCompare = (vars: Partial<ChatVariable>[]) => {
  return [...(vars || [])]
    .map((v) => ({ key: normalizeText(v.key), value: String(v.value ?? '') }))
    .filter((v) => v.key !== '' || v.value !== '')
    .sort((a, b) => a.key.localeCompare(b.key));
};

export const normalizeChatBlocksForCompare = (blocks: ChatBlockLink[]) => {
  return [...(blocks || [])]
    .map((b) => ({ block: b.block, enabled: Boolean(b.enabled), sequence: Number(b.sequence) || 0 }))
    .sort((a, b) => a.sequence - b.sequence || a.block - b.block);
};

export const normalizeChatToolsForCompare = (bindings: ChatToolBindingLink[]) => {
  return [...(bindings || [])]
    .map((binding) => ({
      alias: normalizeText(binding.alias),
      tool_instance_id: Number(binding.tool_instance_id) || 0,
      enabled: Boolean(binding.enabled),
      sequence: Number(binding.sequence) || 0,
    }))
    .sort((a, b) => a.sequence - b.sequence || a.alias.localeCompare(b.alias) || a.tool_instance_id - b.tool_instance_id);
};

export const normalizeIdList = (ids: number[] | null | undefined) =>
  Array.from(new Set((ids || []).filter((id): id is number => typeof id === 'number' && id > 0))).sort((a, b) => a - b);

export const normalizeNameList = (names: string[] | null | undefined) =>
  Array.from(
    new Set(
      (names || [])
        .filter((name): name is string => typeof name === 'string')
        .map((name) => name.trim().toLocaleLowerCase())
        .filter((name) => name !== '')
    )
  ).sort((a, b) => a.localeCompare(b));

export const buildSendPayload = (
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

export const buildMessageUpdatePayload = (
  contents: Array<{ id: number; content_text: string }> | null,
  removeContentIds: number[],
  uploadIds: string[]
) => ({
  ...(contents && contents.length > 0 ? { contents } : {}),
  ...(removeContentIds.length > 0 ? { remove_content_ids: removeContentIds } : {}),
  ...(uploadIds.length > 0 ? { upload_ids: uploadIds } : {}),
});
