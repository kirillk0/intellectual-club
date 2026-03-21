import type { KnowledgeBlock } from '@/types/api';

export type BlockSource = 'bot' | 'chat' | 'config' | 'user';

export type LinkedBlock = {
  block: KnowledgeBlock;
  source: BlockSource;
  order: number;
};

export type ActiveToolInstance = {
  id: number;
  name: string;
  type: string;
  outlet_online: boolean;
};

export type ChatMessageSearchHit = {
  id: number;
  role: 'user' | 'assistant';
  content: string;
  snippet?: string;
  created_at?: string | null;
  finished_at?: string | null;
  llm_configuration_id?: number | null;
};

export type BranchSearchResults = {
  active: ChatMessageSearchHit[];
  inactive: ChatMessageSearchHit[];
};

export type LeftPanelTab = 'messages' | 'prompt';

export const SOURCE_LABELS: Record<BlockSource, string> = {
  bot: 'Bot',
  chat: 'Chat',
  config: 'Configuration',
  user: 'User',
};
