import { computed, getCurrentScope, onScopeDispose, ref, shallowRef, watch, type ComputedRef, type Ref } from 'vue';
import { api, isHttpError } from '@/api/client';

export type TextDraftSnapshot = { text: string; revision: number; updated_at: string | null };
type Target = { key: string; endpoint: string; accountId: number; legacyKey?: string };
type Session = {
  target: Target; text: string; base: TextDraftSnapshot; initialized: boolean; dirty: boolean;
  conflict: TextDraftSnapshot | null; error: boolean; failed: boolean; localSaved: boolean; saving: boolean;
  consumedRevision: number | null; paused: number; pending: Promise<void> | null; timer: ReturnType<typeof setTimeout> | null;
  maxTimer: ReturnType<typeof setTimeout> | null; retry: number; active: boolean;
};
export type DraftSubmission = { session: Session | null; text: string; revision?: number };
/** A synchronization problem worth surfacing to the user; routine progress is not one. */
export type DraftProblem = 'conflict' | 'offline' | 'error' | 'unprotected';
const requestOptions = { showErrorBanner: false, invalidateServerState: false, retry: false as const, timeoutMs: 5_000 };
const empty = (): TextDraftSnapshot => ({ text: '', revision: 0, updated_at: null });

function recoveryTabId() {
  const key = 'ic.draft.recovery-tab';
  try {
    const existing = sessionStorage.getItem(key);
    if (existing) return existing;
    const id = crypto.randomUUID();
    sessionStorage.setItem(key, id);
    return id;
  } catch {
    return crypto.randomUUID();
  }
}


/** Local recovery and optimistic server synchronization, independent of the edited resource. */
export function useSyncedTextDraft(options: {
  target: ComputedRef<Target | null>;
  value: Ref<string>;
  accountId?: ComputedRef<number | null>;
  onSaved?: (target: Target, snapshot: TextDraftSnapshot) => void;
}) {
  const recoveryId = recoveryTabId();
  const recoveryKey = (target: Target) => `${target.key}.recovery.${recoveryId}`;
  const current = shallowRef<Session | null>(null);
  const tick = ref(0);
  const online = ref(typeof navigator === 'undefined' || navigator.onLine !== false);
  let applying = false;
  let disposed = false;
  const sessions = new Set<Session>();
  const changed = () => { tick.value++; };
  const accountMatches = (s: Session) => (options.accountId?.value ?? options.target.value?.accountId) === s.target.accountId;
  const persist = (s: Session) => {
    try {
      const payload = JSON.stringify({ version: 1, text: s.text, base: s.base, dirty: s.dirty,
        consumedRevision: s.consumedRevision, writer: recoveryId });
      // Each tab owns its recovery slot; late replies cannot erase another tab's edits.
      if (s.dirty || s.consumedRevision !== null) localStorage.setItem(recoveryKey(s.target), payload);
      else localStorage.removeItem(recoveryKey(s.target));
      const existing = JSON.parse(localStorage.getItem(s.target.key) || 'null');
      if (!existing?.dirty || existing.writer === recoveryId || existing.text === s.text) {
        localStorage.setItem(s.target.key, payload);
      }
      s.localSaved = true;
    } catch { s.localSaved = false; }
    changed();
  };
  const display = (s: Session) => {
    if (current.value !== s) return;
    applying = true;
    options.value.value = s.text;
    applying = false;
    changed();
  };
  const clearTimers = (s: Session) => {
    if (s.timer !== null) clearTimeout(s.timer);
    if (s.maxTimer !== null) clearTimeout(s.maxTimer);
    s.timer = s.maxTimer = null;
  };
  const schedule = (s: Session, retry = false) => {
    if (disposed || (!s.active && !s.dirty) || s.paused || s.conflict || !accountMatches(s)) return;
    if (s.timer !== null) clearTimeout(s.timer);
    s.timer = setTimeout(() => { void flush(s); }, retry ? s.retry : 1_000);
    if (!retry && s.maxTimer === null) s.maxTimer = setTimeout(() => { void flush(s); }, 5_000);
  };
  const adopt = (s: Session, remote: TextDraftSnapshot) => {
    if (!accountMatches(s)) return;
    if (remote.revision < s.base.revision) return;
    if (s.consumedRevision !== null && remote.revision > s.consumedRevision) {
      if (remote.revision === s.consumedRevision + 1 && remote.text === '' && s.base.revision === s.consumedRevision) {
        s.base = remote;
      }
      s.consumedRevision = null;
    }
    if (s.text === remote.text) {
      s.base = remote; s.dirty = false; s.conflict = null;
    } else if (!s.dirty) {
      s.text = remote.text; s.base = remote; s.conflict = null;
    } else if (remote.revision !== s.base.revision) {
      s.conflict = remote;
    } else {
      s.base = remote;
    }
    s.initialized = true; s.error = false; s.retry = 1_000;
    // Edits that failed to save stay reported until a write succeeds, so retries do not blink.
    if (!s.dirty) s.failed = false;
    persist(s); display(s);
  };
  const fetchRemote = async (s: Session) => {
    const payload = await api.get<{ draft: TextDraftSnapshot }>(s.target.endpoint, requestOptions);
    if (!payload?.draft || typeof payload.draft.text !== 'string' || !Number.isSafeInteger(payload.draft.revision)) {
      throw new Error('Invalid draft snapshot');
    }
    adopt(s, payload.draft);
  };
  async function refresh(s = current.value) {
    if (!s || s.paused || !accountMatches(s) || disposed) return;
    if (s.pending) { await s.pending; return refresh(s); }
    if (!online.value) { s.error = true; changed(); return; }
    const work = (async () => {
      try { await fetchRemote(s); }
      catch { s.error = s.failed = true; schedule(s, true); s.retry = Math.min(s.retry * 2, 30_000); }
      finally { changed(); }
    })();
    s.pending = work;
    await work;
    if (s.pending === work) s.pending = null;
    if (s.dirty && !s.error) schedule(s);
  }
  async function flush(s = current.value, allowPaused = false) {
    if (!s || !accountMatches(s) || (s.paused && !allowPaused)) return;
    clearTimers(s);
    if (s.pending) { await s.pending; return flush(s, allowPaused); }
    if (!accountMatches(s) || (s.paused && !allowPaused) || s.conflict) return;
    if (!online.value) { s.error = true; changed(); return; }
    const work = (async () => {
      try {
        if (!s.initialized || s.error) await fetchRemote(s);
        if (!s.dirty || s.conflict || !accountMatches(s)) return;
        const text = s.text;
        const revision = s.base.revision;
        s.saving = true; changed();
        const payload = await api.put<{ draft: TextDraftSnapshot }>(s.target.endpoint,
          { text, expected_revision: revision }, requestOptions);
        if (!accountMatches(s)) return;
        s.base = payload.draft;
        s.dirty = s.text !== payload.draft.text;
        s.error = s.failed = false; s.retry = 1_000;
        persist(s);
        options.onSaved?.(s.target, payload.draft);
      } catch (error) {
        const remote = isHttpError(error) && error.status === 409
          ? (error.bodyJson as { draft?: TextDraftSnapshot } | null)?.draft : null;
        if (remote) adopt(s, remote);
        else { s.error = s.failed = true; s.retry = Math.min(s.retry * 2, 30_000); }
      } finally { s.saving = false; changed(); }
    })();
    s.pending = work;
    await work;
    if (s.pending === work) s.pending = null;
    if ((s.dirty || s.error) && !s.conflict) schedule(s, s.error);
  }
  const stopWatch = watch(options.target, (target) => {
    const previous = current.value;
    if (previous && target?.key === previous.target.key) return;
    if (previous) {
      previous.active = false; clearTimers(previous);
      if (accountMatches(previous)) void flush(previous);
    }
    current.value = null;
    if (previous || target) { applying = true; options.value.value = ''; applying = false; }
    if (!target) return;
    const existing = [...sessions].find((session) => session.target.key === target.key);
    if (existing) {
      existing.active = true; current.value = existing; display(existing); void refresh(existing); return;
    }
    const s: Session = { target, text: '', base: empty(), initialized: false, dirty: false,
      conflict: null, error: false, failed: false, localSaved: true, saving: false, consumedRevision: null, paused: 0,
      pending: null, timer: null, maxTimer: null, retry: 1_000, active: true };
    try {
      const raw = localStorage.getItem(recoveryKey(target)) || localStorage.getItem(target.key);
      if (raw) {
        const saved = JSON.parse(raw);
        if (saved.version === 1 && typeof saved.text === 'string' && typeof saved.dirty === 'boolean' &&
          typeof saved.base?.text === 'string' && Number.isSafeInteger(saved.base?.revision)) {
          s.text = saved.text; s.base = saved.base; s.dirty = saved.dirty;
          s.consumedRevision = Number.isSafeInteger(saved.consumedRevision) ? saved.consumedRevision : null;
        }
      } else if (target.legacyKey) {
        const legacy = JSON.parse(localStorage.getItem(target.legacyKey) || 'null');
        if (legacy?.version === 1 && typeof legacy.text === 'string') {
          s.text = legacy.text; s.dirty = s.text !== '';
          // The caller only supplies legacyKey after verifying ownership of the target.
          persist(s);
          if (s.localSaved) localStorage.removeItem(target.legacyKey);
        }
      }
    } catch { s.localSaved = false; }
    sessions.add(s); current.value = s; display(s); void refresh(s);
  }, { immediate: true, flush: 'sync' });
  const stopValueWatch = watch(options.value, (text) => {
    const s = current.value;
    if (applying || !s) return;
    s.text = text; s.dirty = text !== s.base.text;
    persist(s); schedule(s);
  }, { flush: 'sync' });
  const state = computed(() => {
    void tick.value;
    const s = current.value;
    if (!s) return 'idle';
    if (s.conflict) return 'conflict';
    if (s.saving) return 'saving';
    if (!online.value) return s.localSaved ? 'offline' : 'unprotected';
    if (s.error) return s.localSaved ? 'error' : 'unprotected';
    if (s.dirty) return s.localSaved ? 'pending' : 'unprotected';
    if (!s.initialized) return 'loading';
    return s.text !== '' ? 'saved' : 'idle';
  });
  const problem = computed<DraftProblem | null>(() => {
    void tick.value;
    const s = current.value;
    if (!s) return null;
    if (s.conflict) return 'conflict';
    if (!s.dirty) return null;
    if (!online.value) return s.localSaved ? 'offline' : 'unprotected';
    if (s.failed) return s.localSaved ? 'error' : 'unprotected';
    return null;
  });
  /** Whether any session of the current account still has edits the server has not acknowledged. */
  const unsaved = computed(() => {
    void tick.value;
    return [...sessions].some((s) => s.dirty && accountMatches(s));
  });
  const conflict = computed(() => { void tick.value; return current.value?.conflict ?? null; });
  const localSaved = computed(() => { void tick.value; return current.value?.localSaved ?? false; });
  const resolve = (choice: 'local' | 'server') => {
    const s = current.value;
    if (!s?.conflict) return;
    const remote = s.conflict;
    s.base = remote; s.conflict = null;
    if (choice === 'server') s.text = remote.text;
    s.dirty = s.text !== remote.text;
    persist(s); display(s);
    if (s.dirty) void flush(s);
  };
  const beginSubmission = async (text: string): Promise<DraftSubmission> => {
    const s = current.value;
    if (!s) return { session: null, text };
    s.paused++; clearTimers(s);
    await flush(s, true);
    return { session: s, text, ...(s.initialized && !s.conflict && s.base.text === text ? { revision: s.base.revision } : {}) };
  };
  const finishSubmission = async (token: DraftSubmission, accepted: boolean) => {
    const s = token.session;
    if (!s) return;
    if (accepted) {
      // Accepted sends consume only their revision; subsequent edits retain that new base.
      if (token.revision !== undefined && s.base.revision === token.revision) {
        s.consumedRevision = token.revision;
      }
      if (s.text === token.text) s.text = '';
      s.dirty = s.text !== s.base.text;
      persist(s); display(s);
      options.onSaved?.(s.target, s.base);
    }
    s.paused = Math.max(0, s.paused - 1);
    if (s.active) await refresh(s);
    if (s.dirty) void flush(s);
  };
  const wake = () => {
    online.value = navigator.onLine !== false;
    void refresh();
    if (online.value) {
      for (const s of sessions) {
        if (s !== current.value && s.dirty && accountMatches(s)) void flush(s);
      }
    }
  };
  const visibility = () => {
    if (document.visibilityState === 'hidden') void flush();
    else wake();
  };
  const beforeUnload = (event: BeforeUnloadEvent) => {
    if (!unsaved.value) return;
    // Local recovery survives, but other devices would not see the edits: ask the browser to confirm.
    event.preventDefault();
    event.returnValue = '';
  };
  window.addEventListener('online', wake);
  window.addEventListener('offline', wake);
  window.addEventListener('focus', wake);
  window.addEventListener('pageshow', wake);
  document.addEventListener('visibilitychange', visibility);
  window.addEventListener('beforeunload', beforeUnload);
  const dispose = () => {
    if (disposed) return;
    stopWatch(); stopValueWatch();
    for (const s of sessions) { clearTimers(s); s.active = false; }
    void flush(); disposed = true;
    window.removeEventListener('online', wake); window.removeEventListener('offline', wake);
    window.removeEventListener('focus', wake); window.removeEventListener('pageshow', wake);
    document.removeEventListener('visibilitychange', visibility);
    window.removeEventListener('beforeunload', beforeUnload);
  };
  if (getCurrentScope()) onScopeDispose(dispose);
  return { state, problem, unsaved, conflict, localSaved, refresh, flush: () => flush(), resolve, beginSubmission, finishSubmission, dispose };
}
