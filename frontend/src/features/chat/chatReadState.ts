import { api } from '@/api/client';
import type { ChatReadState } from '@/types/api';

export type ChatReadStateAction = 'read' | 'unread' | 'snooze' | 'unsnooze';
export type ChatReadStateInput = {
  action: ChatReadStateAction;
  expected_state_version: number;
  observed_revision?: number;
  snoozed_until?: string;
  explicit?: boolean;
};

export function chatReadStateInput(
  state: ChatReadState,
  action: ChatReadStateAction,
  options: Pick<ChatReadStateInput, 'explicit' | 'snoozed_until'> = {}
): ChatReadStateInput {
  return {
    action,
    expected_state_version: state.state_version,
    ...(action === 'read' ? { observed_revision: state.activity_revision, explicit: true } : {}),
    ...options,
  };
}

export async function updateChatReadState(chatId: number, input: ChatReadStateInput): Promise<ChatReadState> {
  const payload = await api.post<{ read_state: ChatReadState }>(
    `/api/bff/chat-state/${chatId}/read-state`, input, { retry: false, showErrorBanner: false }
  );
  return payload.read_state;
}

export function isChatReadStateConflict(error: unknown): boolean {
  return error != null && typeof error === 'object' && 'status' in error && error.status === 409;
}

export function isFutureSnooze(value: string): boolean {
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) && timestamp > Date.now();
}
