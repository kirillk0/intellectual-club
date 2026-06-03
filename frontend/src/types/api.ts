export type SessionUser = {
  id: number;
  username: string;
  is_admin: boolean;
  preferred_locale: 'en' | 'ru' | null;
  preferred_theme: 'system' | 'light' | 'dark';
};

export type AdminUser = {
  id: number;
  username: string;
  is_admin: boolean;
  created_at?: string | null;
  updated_at?: string | null;
  groups?: AdminUserGroupSummary[];
};

type AdminUserSummary = {
  id: number;
  username: string;
  is_admin: boolean;
};

export type AdminUserGroupSummary = {
  id: number;
  name: string;
};

export type AdminUserGroup = {
  id: number;
  name: string;
  created_at?: string | null;
  updated_at?: string | null;
  users?: AdminUserSummary[];
};

export type Group = {
  id: number;
  name: string;
};

export type ImageAsset = {
  url: string;
  filename: string;
  mime_type: string;
  size_bytes: number;
  sha256: string;
};

export type KnowledgeBlockAttachment = {
  id: number;
  external_id: string;
  file_id: string;
  filename: string;
  mime_type: string;
  size_bytes: number;
  sha256: string;
  sequence: number;
  enabled: boolean;
  url: string;
};

export type Bot = {
  id: number;
  name: string;
  image?: ImageAsset | null;
  default_llm_configuration_id?: number | null;
  compatible_configuration_tag_ids?: number[];
  compatible_configuration_tag_names?: string[];
  context_soft_limit_percent?: number | null;
  max_file_size_bytes?: number | null;
  can_edit?: boolean;
  shared_incoming?: boolean;
  shared_outgoing?: boolean;
  created_at?: string | null;
  updated_at?: string | null;
  sort_activity_at?: string | null;
};

export type LlmConfiguration = {
  id: number;
  label: string;
  enabled: boolean;
  tag_ids?: number[];
  tag_names?: string[];
  context_length?: number | null;
  supports_image_input?: boolean | null;
  can_edit?: boolean;
  shared_incoming?: boolean;
  shared_outgoing?: boolean;
};

export type KnowledgeBlock = {
  id: number;
  name: string;
  image?: ImageAsset | null;
  version: string | null;
  token_count: number | null;
  can_edit?: boolean;
  shared_incoming?: boolean;
  shared_outgoing?: boolean;
};

export type ToolInstanceOption = {
  id: number;
  name: string;
  description?: string | null;
  alias: string;
  type: string;
  type_title?: string | null;
  outlet_online?: boolean | null;
  can_edit?: boolean | null;
};

export type UserKnowledgeBlock = {
  id: number;
  knowledge_block_id: number;
  enabled: boolean;
  sequence: number;
  knowledge_block?: KnowledgeBlock | null;
};

export type ChatVariable = {
  key: string;
  value: string;
};

export type Chat = {
  id: number;
  title: string;
  note: string;
  bot_id: number | null;
  llm_configuration_id: number | null;
  variables: ChatVariable[];
  parent_chat_id?: number | null;
  parent_message_id?: number | null;
  parent_relation_kind?: string | null;
  can_edit?: boolean | null;
  shared_incoming?: boolean | null;
  shared_outgoing?: boolean | null;
  created_at?: string | null;
  updated_at?: string | null;
};

export type ChatRelationSummary = {
  chat_id: number;
  message_id?: number | null;
  parent_chat_id?: number | null;
  parent_message_id?: number | null;
  kind?: string | null;
  title?: string | null;
  note?: string | null;
  bot_id?: number | null;
  bot_name?: string | null;
  active_generation_message_id?: number | null;
  created_at?: string | null;
  updated_at?: string | null;
};

export type ChatRelations = {
  parent: ChatRelationSummary | null;
  children_by_message_id: Record<string, ChatRelationSummary[]>;
  children_without_message: ChatRelationSummary[];
};

export type ChatKnowledgeBlock = {
  id: number;
  chat_id: number;
  knowledge_block_id: number;
  enabled: boolean;
  sequence: number;
  knowledge_block?: KnowledgeBlock | null;
};

export type ChatToolBinding = {
  id: number;
  chat_id: number;
  tool_instance_id: number;
  alias: string;
  enabled: boolean;
  sequence: number;
  tool_instance?: ToolInstanceOption | null;
};

export type ActiveToolBinding = {
  id: number;
  source: 'bot' | 'user' | 'chat' | string;
  alias: string;
  sequence: number;
  tool_instance_id: number;
  tool_instance?: ToolInstanceOption | null;
};

export type ChatMessageContent = {
  id: number;
  external_id?: string | null;
  sequence: number;
  kind: 'text' | 'opaque' | 'media' | string;
  content_text?: string | null;
  content_text_truncated?: boolean;
  content_json?: unknown;
  media?: {
    external_id: string;
    filename: string;
    mime_type: string;
    size_bytes: number;
    sha256: string;
    is_image: boolean;
  } | null;
};

export type ChatMessageItem = {
  id: number;
  sequence: number;
  created_at?: string | null;
  type: string;
  tool_call_item_id?: number | null;
  contents?: ChatMessageContent[] | null;
};

export type ChatMessageStep = {
  id: number;
  sequence: number;
  created_at?: string | null;
  finished_at?: string | null;
  time_to_first_token_ms?: number | null;
  tokens_per_second?: number | null;
  status?: string | null;
  response_final?: boolean | null;
  input_tokens?: number | null;
  output_tokens?: number | null;
  cached_input_tokens?: number | null;
  reasoning_tokens?: number | null;
  cost?: number | null;
  items?: ChatMessageItem[] | null;
};

export type ChatMessageContentPart = {
  step_id?: number | null;
  step_sequence?: number | null;
  item_id?: number | null;
  item_sequence?: number | null;
  content_id: number;
  sequence: number;
  text: string;
  content_text_truncated?: boolean;
  created_at?: string | null;
};

export type ChatMessageUsage = {
  latest_step?: Omit<ChatMessageStep, 'items'> | null;
  total_cost?: number | null;
};

export type ChatMessageWorkingSummary = {
  step_count: number;
  latest_step_id?: number | null;
  latest_step_sequence?: number | null;
  latest_step_status?: string | null;
  completed_step_duration_ms: number;
  active_step_started_at?: string | null;
};

export type ChatMessageContentSnapshot = {
  parts: ChatMessageContentPart[];
  media: ChatMessageContent[];
};

export type ChatBranchMessage = {
  id: number;
  parent_id?: number | null;
  role: 'user' | 'assistant';
  status: 'generating' | 'done' | 'canceled' | 'error' | string;
  bookmarked?: boolean;
  error_detail?: string | null;
  token_count?: number | null;
  created_at?: string | null;
  finished_at?: string | null;
  llm_configuration_id?: number | null;
  content?: ChatMessageContentSnapshot | null;
  usage?: ChatMessageUsage | null;
  working?: ChatMessageWorkingSummary | null;
  steps?: ChatMessageStep[] | null;
  prev_sibling_id?: number | null;
  next_sibling_id?: number | null;
  siblings?: { id: number; size: number; active: boolean }[];
};
