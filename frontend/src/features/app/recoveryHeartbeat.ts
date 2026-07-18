export type RecoveryHeartbeatReason =
  | 'subscribe'
  | 'manual'
  | 'interval'
  | 'online'
  | 'offline'
  | 'focus'
  | 'pageshow'
  | 'visibilitychange'
  | 'resume';

export type RecoveryHeartbeatPulse = {
  reason: RecoveryHeartbeatReason;
  visible: boolean;
  onlineHint: boolean;
  at: number;
};

type RecoveryHeartbeatListener = (pulse: RecoveryHeartbeatPulse) => void;

type RecoveryHeartbeatSubscriptionOptions = {
  immediate?: boolean;
};

const VISIBLE_INTERVAL_MS = 10_000;
const HIDDEN_INTERVAL_MS = 30_000;

const listeners = new Set<RecoveryHeartbeatListener>();

let timer: number | null = null;
let started = false;

const isVisible = () =>
  typeof document === 'undefined' || document.visibilityState !== 'hidden';

const onlineHint = () =>
  typeof navigator === 'undefined' || navigator.onLine !== false;

const snapshot = (reason: RecoveryHeartbeatReason): RecoveryHeartbeatPulse => ({
  reason,
  visible: isVisible(),
  onlineHint: onlineHint(),
  at: Date.now(),
});

const emit = (reason: RecoveryHeartbeatReason) => {
  const pulse = snapshot(reason);
  [...listeners].forEach((listener) => {
    try {
      listener(pulse);
    } catch (error) {
      console.error('Recovery heartbeat listener failed.', error);
    }
  });
};

const clearTimer = () => {
  if (timer === null) return;
  window.clearTimeout(timer);
  timer = null;
};

const scheduleTimer = () => {
  clearTimer();
  if (!started) return;

  timer = window.setTimeout(() => {
    timer = null;
    emit('interval');
    scheduleTimer();
  }, isVisible() ? VISIBLE_INTERVAL_MS : HIDDEN_INTERVAL_MS);
};

const handleWindowEvent = (event: Event) => {
  const reason =
    event.type === 'online' ||
    event.type === 'offline' ||
    event.type === 'focus' ||
    event.type === 'pageshow'
      ? event.type
      : 'manual';
  emit(reason);
  scheduleTimer();
};

const handleDocumentEvent = (event: Event) => {
  const reason = event.type === 'resume' ? 'resume' : 'visibilitychange';
  emit(reason);
  scheduleTimer();
};

const start = () => {
  if (started || typeof window === 'undefined' || typeof document === 'undefined') return;
  started = true;

  window.addEventListener('online', handleWindowEvent);
  window.addEventListener('offline', handleWindowEvent);
  window.addEventListener('focus', handleWindowEvent);
  window.addEventListener('pageshow', handleWindowEvent);
  document.addEventListener('visibilitychange', handleDocumentEvent);
  document.addEventListener('resume', handleDocumentEvent);
  scheduleTimer();
};

const stop = () => {
  if (!started || listeners.size > 0) return;
  started = false;
  clearTimer();

  window.removeEventListener('online', handleWindowEvent);
  window.removeEventListener('offline', handleWindowEvent);
  window.removeEventListener('focus', handleWindowEvent);
  window.removeEventListener('pageshow', handleWindowEvent);
  document.removeEventListener('visibilitychange', handleDocumentEvent);
  document.removeEventListener('resume', handleDocumentEvent);
};

export const subscribeRecoveryHeartbeat = (
  listener: RecoveryHeartbeatListener,
  options: RecoveryHeartbeatSubscriptionOptions = {}
) => {
  listeners.add(listener);
  start();
  if (options.immediate) listener(snapshot('subscribe'));

  return () => {
    listeners.delete(listener);
    stop();
  };
};

export const requestRecoveryNow = () => {
  if (listeners.size === 0) return;
  start();
  emit('manual');
  scheduleTimer();
};
