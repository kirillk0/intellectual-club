export type SessionUser = {
  id: number;
  username: string;
  is_admin: boolean;
};

export type AdminUser = {
  id: number;
  username: string;
  is_admin: boolean;
  created_at?: string | null;
  updated_at?: string | null;
  groups?: AdminUserGroupSummary[];
};

export type AdminUserSummary = {
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

export type Bot = {
  id: number;
  name: string;
  image?: ImageAsset | null;
  compatible_configuration_tag_ids?: number[];
  context_soft_limit_percent?: number | null;
  supports_file_processing?: boolean | null;
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
  type: string | null;
  version: string | null;
  token_count: number | null;
  can_edit?: boolean;
  shared_incoming?: boolean;
  shared_outgoing?: boolean;
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
  created_at?: string | null;
  updated_at?: string | null;
};

export type ChatKnowledgeBlock = {
  id: number;
  chat_id: number;
  knowledge_block_id: number;
  enabled: boolean;
  sequence: number;
  knowledge_block?: KnowledgeBlock | null;
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
  type: string;
  contents?: ChatMessageContent[] | null;
};

export type ChatMessageStep = {
  id: number;
  sequence: number;
  created_at?: string | null;
  status?: string | null;
  response_final?: boolean | null;
  input_tokens?: number | null;
  output_tokens?: number | null;
  cached_input_tokens?: number | null;
  reasoning_tokens?: number | null;
  cost?: number | null;
  items?: ChatMessageItem[] | null;
};

export type ChatBranchMessage = {
  id: number;
  parent_id?: number | null;
  role: 'user' | 'assistant';
  status: 'generating' | 'done' | 'canceled' | 'error' | string;
  error_detail?: string | null;
  token_count?: number | null;
  created_at?: string | null;
  llm_configuration_id?: number | null;
  steps?: ChatMessageStep[] | null;
  prev_sibling_id?: number | null;
  next_sibling_id?: number | null;
  siblings?: { id: number; size: number; active: boolean }[];
};
