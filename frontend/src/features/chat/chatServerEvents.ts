import { onBeforeUnmount } from 'vue';
import { publishChatChange } from '@/features/chat/chatEvents';

export type ChatServerEvent = { chatId: number | null; kind?: 'draft' };
type Handler = (event: ChatServerEvent) => void;

const listeners = new Set<Handler>();
const MIN_RETRY_MS = 1_000;
const MAX_RETRY_MS = 30_000;
let source: EventSource | null = null;
let detachSource: (() => void) | null = null;
let connected = false;
let started = false;
let retryTimer: number | null = null;
let retryDelay = MIN_RETRY_MS;

function notify(listener: Handler, event: ChatServerEvent) {
  try {
    listener(event);
  } catch (error) {
    console.error('Chat server event listener failed.', error);
  }
}

function publish(event: ChatServerEvent) {
  for (const listener of [...listeners]) notify(listener, event);
}

function canConnect() {
  return listeners.size > 0 && typeof window !== 'undefined' &&
    typeof window.EventSource === 'function' && document.visibilityState !== 'hidden' &&
    navigator.onLine !== false;
}

function clearRetry() {
  if (retryTimer !== null) window.clearTimeout(retryTimer);
  retryTimer = null;
}

function closeSource() {
  detachSource?.();
  detachSource = null;
  source?.close();
  source = null;
  connected = false;
}

function scheduleRetry() {
  if (!canConnect() || retryTimer !== null) return;
  const delay = retryDelay;
  retryDelay = Math.min(retryDelay * 2, MAX_RETRY_MS);
  retryTimer = window.setTimeout(() => {
    retryTimer = null;
    connect();
  }, delay);
}

function connect() {
  if (!canConnect() || source !== null || retryTimer !== null) return;
  let current: EventSource;
  try {
    current = new window.EventSource('/api/bff/chat-events');
  } catch {
    scheduleRetry();
    return;
  }
  source = current;
  const handleOpen = () => {
    if (source !== current) return;
    connected = true;
    retryDelay = MIN_RETRY_MS;
    // There is no event replay; snapshots repair any disconnected interval.
    publish({ chatId: null });
  };
  const handleError = () => {
    if (source !== current) return;
    closeSource();
    scheduleRetry();
  };
  const handleMessage = (event: MessageEvent) => {
    if (source !== current || typeof event.data !== 'string') return;
    try {
      const payload: unknown = JSON.parse(event.data);
      if (payload === null || typeof payload !== 'object' || !('chat_id' in payload)) return;
      const id = payload.chat_id;
      if (typeof id === 'number' && Number.isSafeInteger(id) && id > 0) {
        if (event.type === 'chat_draft_changed') {
          publishChatChange({ operation: 'touch', id, meta: { reason: 'draft-changed', revision: 'revision' in payload ? payload.revision : undefined } });
        }
        publish({ chatId: id, ...(event.type === 'chat_draft_changed' ? { kind: 'draft' as const } : {}) });
      }
    } catch {
      // A malformed invalidation must not interrupt existing polling recovery.
    }
  };
  current.addEventListener('open', handleOpen);
  current.addEventListener('error', handleError);
  current.addEventListener('chat_state_changed', handleMessage as EventListener);
  current.addEventListener('chat_draft_changed', handleMessage as EventListener);
  detachSource = () => {
    current.removeEventListener('open', handleOpen);
    current.removeEventListener('error', handleError);
    current.removeEventListener('chat_state_changed', handleMessage as EventListener);
    current.removeEventListener('chat_draft_changed', handleMessage as EventListener);
  };
}

function handleWake() {
  if (!canConnect()) {
    clearRetry();
    closeSource();
    return;
  }
  connect();
}

function start() {
  if (started || typeof window === 'undefined') return;
  started = true;
  document.addEventListener('visibilitychange', handleWake);
  document.addEventListener('resume', handleWake);
  window.addEventListener('online', handleWake);
  window.addEventListener('offline', handleWake);
  window.addEventListener('focus', handleWake);
  window.addEventListener('pageshow', handleWake);
  connect();
}

function stop() {
  if (!started || listeners.size > 0) return;
  started = false;
  clearRetry();
  closeSource();
  retryDelay = MIN_RETRY_MS;
  document.removeEventListener('visibilitychange', handleWake);
  document.removeEventListener('resume', handleWake);
  window.removeEventListener('online', handleWake);
  window.removeEventListener('offline', handleWake);
  window.removeEventListener('focus', handleWake);
  window.removeEventListener('pageshow', handleWake);
}

export function subscribeChatServerEvents(handler: Handler) {
  // Each subscription owns its own entry even when callers reuse the same handler.
  const listener: Handler = (event) => handler(event);
  listeners.add(listener);
  if (connected) notify(listener, { chatId: null });
  start();
  return () => {
    listeners.delete(listener);
    stop();
  };
}

export function useChatServerEvents(handler: Handler) {
  const unsubscribe = subscribeChatServerEvents(handler);
  onBeforeUnmount(unsubscribe);
  return unsubscribe;
}
