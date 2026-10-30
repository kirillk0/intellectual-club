import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch, type Ref } from 'vue';
import { chatReadStateInput, isChatReadStateConflict, updateChatReadState } from '@/features/chat/chatReadState';
import { publishChatChange } from '@/features/chat/chatEvents';
import type { ChatReadState } from '@/types/api';

type ReadAction = 'read' | 'unread' | 'snooze' | 'unsnooze';
type Options = {
  chatId: Readonly<Ref<number>>;
  active: Readonly<Ref<boolean>>;
  refresh: () => Promise<void>;
};

export function useChatReadStateRuntime(options: Options) {
  const state = ref<ChatReadState | null>(null);
  const busy = ref(false);
  const now = ref(Date.now());
  const visible = ref(document.visibilityState === 'visible');
  const focused = ref(document.hasFocus());
  const present = computed(() => options.active.value && visible.value && focused.value);
  const isSnoozed = computed(() => Boolean(state.value?.snoozed_until &&
    Date.parse(state.value.snoozed_until) > now.value));
  const isUnread = computed(() => Boolean(state.value?.has_unread && !isSnoozed.value));
  let disposed = false;
  let visit = 0;
  let displayedRevision = 0;
  let pendingEntry = true;
  let blockedVisit = false;
  let inFlight: Promise<void> | null = null;
  let deadlineTimer: number | null = null;
  let retryTimer: number | null = null;
  let retryStateVersion: number | null = null;

  function clearReadRetry() {
    if (retryTimer !== null) window.clearTimeout(retryTimer);
    retryTimer = null;
    retryStateVersion = null;
  }

  function scheduleDeadline() {
    if (deadlineTimer !== null) window.clearTimeout(deadlineTimer);
    deadlineTimer = null;
    now.value = Date.now();
    const until = state.value?.snoozed_until ? Date.parse(state.value.snoozed_until) : 0;
    if (until > now.value) {
      deadlineTimer = window.setTimeout(() => {
        deadlineTimer = null;
        // Expiry changes presentation, not whether this visit has read the chat.
        scheduleDeadline();
      }, Math.min(until - now.value + 20, 2_147_483_647));
    }
  }

  function applyState(next: ChatReadState) {
    const current = state.value;
    if (current && (next.state_version < current.state_version ||
      next.activity_revision < current.activity_revision)) return;
    state.value = next;
    scheduleDeadline();
  }

  async function write(action: ReadAction, explicit: boolean, until?: string) {
    const current = state.value;
    if (!current || disposed) return;
    const id = options.chatId.value;
    const input = chatReadStateInput(current, action, {
      ...(action === 'read' ? { explicit } : {}),
      ...(until ? { snoozed_until: until } : {}),
    });
    if (action === 'read') input.observed_revision = displayedRevision;
    const next = await updateChatReadState(id, input);
    if (!disposed && id === options.chatId.value) applyState(next);
    publishChatChange({ operation: 'touch', id, meta: { reason: 'read-state' } });
  }

  async function acknowledge() {
    await nextTick();
    if (disposed || !present.value || blockedVisit || busy.value || inFlight || !state.value) return;
    if (retryStateVersion !== null && state.value.state_version !== retryStateVersion) {
      // A fresh personal intent supersedes the failed entry acknowledgement.
      pendingEntry = false;
      clearReadRetry();
    }
    const explicit = pendingEntry;
    pendingEntry = false;
    if (!state.value.has_unread) return;
    if (!state.value.manual_unread && displayedRevision <= state.value.read_revision) return;
    if (!explicit && (state.value.manual_unread || isSnoozed.value)) return;
    const currentVisit = visit;
    const expectedVersion = state.value.state_version;
    const id = options.chatId.value;
    const request = write('read', explicit).then(() => {
      if (visit === currentVisit) clearReadRetry();
    }).catch((error: unknown) => {
      if (disposed || id !== options.chatId.value || visit !== currentVisit) return;
      // Never retry a stale acknowledgement using a newer manual state's version.
      if (isChatReadStateConflict(error)) {
        blockedVisit = true;
        clearReadRetry();
        void options.refresh();
      } else {
        console.warn('Failed to acknowledge chat read state.', error);
        if (blockedVisit || busy.value) return;
        pendingEntry = explicit;
        retryStateVersion = expectedVersion;
        if (retryTimer !== null) window.clearTimeout(retryTimer);
        retryTimer = window.setTimeout(async () => {
          retryTimer = null;
          if (disposed || !present.value || visit !== currentVisit || blockedVisit) return;
          try {
            await options.refresh();
          } catch (refreshError) {
            console.warn('Failed to refresh chat before acknowledging read state.', refreshError);
          } finally {
            void acknowledge();
          }
        }, 2_000);
      }
    });
    inFlight = request;
    try {
      await request;
    } finally {
      if (inFlight === request) inFlight = null;
      if (!disposed && id !== options.chatId.value) void acknowledge();
    }
  }

  function receiveSnapshot(next?: ChatReadState | null) {
    if (!next || disposed) return;
    displayedRevision = next.activity_revision;
    applyState(next);
    void acknowledge();
  }

  async function mutate(action: ReadAction, until?: string) {
    if (busy.value || !state.value) return;
    const id = options.chatId.value;
    blockedVisit = true;
    clearReadRetry();
    pendingEntry = false;
    busy.value = true;
    try {
      // Serialize local intent after an acknowledgement already accepted by the server.
      await inFlight;
      if (disposed || id !== options.chatId.value) return;
      await write(action, true, until);
      if (id === options.chatId.value && action === 'read') blockedVisit = false;
    } catch (error) {
      if (!disposed && id === options.chatId.value) await options.refresh();
      throw error;
    } finally {
      busy.value = false;
      if (!disposed && id !== options.chatId.value) void acknowledge();
    }
  }

  function syncPresence() {
    visible.value = document.visibilityState === 'visible';
    focused.value = document.hasFocus();
    scheduleDeadline();
  }

  watch(present, (active, previous) => {
    if (active === previous) return;
    visit += 1;
    clearReadRetry();
    if (!active) return;
    blockedVisit = false;
    pendingEntry = true;
    // Read only after the newly activated view has loaded a fresh snapshot.
    void options.refresh();
  }, { flush: 'sync' });

  watch(options.chatId, () => {
    visit += 1;
    clearReadRetry();
    state.value = null;
    displayedRevision = 0;
    pendingEntry = true;
    blockedVisit = false;
    scheduleDeadline();
  }, { flush: 'sync' });

  onMounted(() => {
    document.addEventListener('visibilitychange', syncPresence);
    window.addEventListener('focus', syncPresence);
    window.addEventListener('blur', syncPresence);
    window.addEventListener('pageshow', syncPresence);
  });
  onBeforeUnmount(() => {
    disposed = true;
    clearReadRetry();
    if (deadlineTimer !== null) window.clearTimeout(deadlineTimer);
    document.removeEventListener('visibilitychange', syncPresence);
    window.removeEventListener('focus', syncPresence);
    window.removeEventListener('blur', syncPresence);
    window.removeEventListener('pageshow', syncPresence);
  });

  return {
    state,
    busy,
    isUnread,
    isSnoozed,
    receiveSnapshot,
    markRead: () => mutate('read'),
    markUnread: () => mutate('unread'),
    snooze: (until: string) => mutate('snooze', until),
    unsnooze: () => mutate('unsnooze'),
  };
}
