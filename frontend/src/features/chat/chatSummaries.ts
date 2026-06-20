import { api } from '@/api/client';
import type { ChatSummary } from '@/types/api';

export async function fetchChatSummary(chatId: number, previewLength = 200): Promise<ChatSummary> {
  const params = new URLSearchParams();
  params.set('preview_len', String(Math.min(Math.max(1, previewLength), 500)));

  const payload = await api.get<{ chat: ChatSummary }>(
    `/api/bff/chat-list/${chatId}/summary?${params.toString()}`,
    { showErrorBanner: false }
  );

  return payload.chat;
}
