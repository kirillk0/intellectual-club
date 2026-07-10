import { onBeforeUnmount } from 'vue';

export type ChatChangeOperation = 'upsert' | 'delete' | 'touch';

export type ChatChange = {
  operation: ChatChangeOperation;
  id: number;
  row?: unknown;
  patch?: Record<string, unknown>;
  meta?: Record<string, unknown>;
  timestamp: number;
};

type ChatChangeInput = Omit<ChatChange, 'timestamp'>;
type ChatChangeHandler = (change: ChatChange) => void;

const listeners = new Set<ChatChangeHandler>();

export function publishChatChange(change: ChatChangeInput) {
  if (!Number.isInteger(change.id) || change.id <= 0) return;

  const payload: ChatChange = {
    ...change,
    timestamp: Date.now(),
  };

  for (const listener of Array.from(listeners)) {
    listener(payload);
  }
}

export function subscribeChatChanges(handler: ChatChangeHandler) {
  listeners.add(handler);
  return () => {
    listeners.delete(handler);
  };
}

export function useChatChanges(handler: ChatChangeHandler) {
  const unsubscribe = subscribeChatChanges(handler);
  onBeforeUnmount(unsubscribe);
  return unsubscribe;
}
