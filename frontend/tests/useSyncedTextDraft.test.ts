import { computed, effectScope, ref } from 'vue';
import { flushPromises } from '@vue/test-utils';
const mocks = vi.hoisted(() => ({ get: vi.fn(), put: vi.fn() }));
vi.mock('@/api/client', () => ({ api: mocks, isHttpError: (e: unknown) => Boolean(e && typeof e === 'object' && 'status' in e) }));
import { useSyncedTextDraft, type TextDraftSnapshot } from '@/features/app/useSyncedTextDraft';

const snapshot = (text = '', revision = 0): TextDraftSnapshot => ({ text, revision, updated_at: null });
let server: TextDraftSnapshot;
const scopes: ReturnType<typeof effectScope>[] = [];
const deferred = <T>() => { let resolve!: (value: T) => void; const promise = new Promise<T>((r) => { resolve = r; }); return { promise, resolve }; };
function create(initialAccount = 1, initialChat = 12) {
  const value = ref(''); const account = ref<number | null>(initialAccount); const chat = ref(initialChat);
  const scope = effectScope(); scopes.push(scope);
  const onSaved = vi.fn();
  const sync = scope.run(() => useSyncedTextDraft({
    value, accountId: computed(() => account.value), onSaved,
    target: computed(() => account.value ? {
      accountId: account.value, key: `draft.${account.value}.${chat.value}`, endpoint: `/drafts/${chat.value}`,
    } : null),
  }))!;
  return { value, account, chat, sync, onSaved, scope };
}

beforeEach(() => {
  vi.useFakeTimers(); localStorage.clear(); sessionStorage.clear(); server = snapshot();
  vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true);
  mocks.get.mockReset().mockImplementation(async () => ({ draft: { ...server } }));
  mocks.put.mockReset().mockImplementation(async (_url, body) => {
    if (body.expected_revision !== server.revision) throw { status: 409, bodyJson: { draft: { ...server } } };
    server = snapshot(body.text, server.revision + 1); return { draft: { ...server } };
  });
});
afterEach(async () => { scopes.splice(0).forEach((s) => s.stop()); await flushPromises(); vi.useRealTimers(); vi.restoreAllMocks(); });

it('persists locally immediately and saves only the last text after a pause', async () => {
  const { value, sync } = create(); await flushPromises();
  value.value = 'a'; await vi.advanceTimersByTimeAsync(700); value.value = 'ab';
  expect(JSON.parse(localStorage.getItem('draft.1.12')!).text).toBe('ab');
  expect(sync.state.value).toBe('pending');
  await vi.advanceTimersByTimeAsync(999); expect(mocks.put).not.toHaveBeenCalled();
  await vi.advanceTimersByTimeAsync(1);
  expect(mocks.put).toHaveBeenCalledTimes(1); expect(server.text).toBe('ab'); expect(sync.state.value).toBe('saved');
  await vi.advanceTimersByTimeAsync(20_000); expect(mocks.put).toHaveBeenCalledTimes(1);
});

it('saves during continuous typing at the maximum wait', async () => {
  const { value } = create(); await flushPromises();
  for (let i = 0; i < 10; i++) { value.value += 'x'; await vi.advanceTimersByTimeAsync(500); }
  expect(mocks.put).toHaveBeenCalledTimes(1); expect(server.text).toBe('xxxxxxxxxx');
});

it('serializes writes and keeps edits made while saving dirty', async () => {
  const { value, sync } = create(); await flushPromises();
  const pending = deferred<{ draft: TextDraftSnapshot }>(); mocks.put.mockReturnValueOnce(pending.promise);
  value.value = 'first'; await vi.advanceTimersByTimeAsync(1_000); value.value = 'second';
  await vi.advanceTimersByTimeAsync(5_000); expect(mocks.put).toHaveBeenCalledTimes(1);
  server = snapshot('first', 1); pending.resolve({ draft: server }); await flushPromises();
  await vi.advanceTimersByTimeAsync(1_000);
  expect(server.text).toBe('second'); expect(sync.state.value).toBe('saved');
});

it('does not overwrite local typing with a delayed server read', async () => {
  const pending = deferred<{ draft: TextDraftSnapshot }>(); mocks.get.mockReturnValueOnce(pending.promise);
  const { value, sync } = create(); value.value = 'local';
  server = snapshot('remote', 3); pending.resolve({ draft: server }); await flushPromises();
  expect(value.value).toBe('local'); expect(sync.state.value).toBe('conflict');
  expect(sync.conflict.value?.text).toBe('remote'); expect(mocks.put).not.toHaveBeenCalled();
  sync.resolve('local'); await flushPromises(); expect(server.text).toBe('local'); expect(server.revision).toBe(4);
});

it('lets the user choose the server version without another write', async () => {
  const { value, sync } = create(); await flushPromises(); value.value = 'local'; server = snapshot('remote', 1);
  await sync.flush(); expect(sync.state.value).toBe('conflict');
  sync.resolve('server'); expect(value.value).toBe('remote'); expect(sync.state.value).toBe('saved');
  expect(mocks.put).toHaveBeenCalledTimes(1);
});

it('rechecks a clean cached snapshot instead of resurrecting an already sent draft', async () => {
  localStorage.setItem('draft.1.12', JSON.stringify({ version: 1, text: 'sent', base: snapshot('sent', 3), dirty: false }));
  server = snapshot('', 4); const { value, sync } = create(); await flushPromises();
  expect(value.value).toBe(''); expect(sync.state.value).toBe('idle'); expect(mocks.put).not.toHaveBeenCalled();
});

it('keeps offline edits and synchronizes them after reconnecting', async () => {
  const { value, sync } = create(); await flushPromises();
  vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false); window.dispatchEvent(new Event('offline'));
  value.value = 'offline'; await vi.advanceTimersByTimeAsync(6_000);
  expect(sync.state.value).toBe('offline'); expect(mocks.put).not.toHaveBeenCalled();
  vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true); window.dispatchEvent(new Event('online'));
  await flushPromises(); await vi.advanceTimersByTimeAsync(1_000);
  expect(server.text).toBe('offline'); expect(sync.state.value).toBe('saved');
});

it('retries a failed write without a notification or losing the local text', async () => {
  const { value, sync } = create(); await flushPromises(); mocks.put.mockRejectedValueOnce(new Error('network'));
  value.value = 'recover'; await vi.advanceTimersByTimeAsync(1_000); expect(sync.state.value).toBe('error');
  await vi.advanceTimersByTimeAsync(2_000); expect(server.text).toBe('recover'); expect(sync.state.value).toBe('saved');
});

it('reports only problems of unsynchronized edits and keeps a failure visible across retries', async () => {
  const { value, sync } = create(); await flushPromises();
  mocks.get.mockRejectedValueOnce(new Error('network')); await sync.refresh();
  expect(sync.state.value).toBe('error'); expect(sync.problem.value).toBeNull();
  await vi.advanceTimersByTimeAsync(2_000); expect(sync.state.value).toBe('idle');
  const retry = deferred<{ draft: TextDraftSnapshot }>();
  mocks.put.mockRejectedValueOnce(new Error('network')).mockReturnValueOnce(retry.promise);
  value.value = 'typed'; expect(sync.state.value).toBe('pending'); expect(sync.problem.value).toBeNull();
  await vi.advanceTimersByTimeAsync(1_000); expect(sync.problem.value).toBe('error');
  await vi.advanceTimersByTimeAsync(2_000);
  expect(sync.state.value).toBe('saving'); expect(sync.problem.value).toBe('error');
  server = snapshot('typed', 1); retry.resolve({ draft: server }); await flushPromises();
  expect(sync.state.value).toBe('saved'); expect(sync.problem.value).toBeNull();
});

it('asks the browser to confirm leaving while edits are not acknowledged by the server', async () => {
  const leave = () => {
    const event = new Event('beforeunload', { cancelable: true });
    window.dispatchEvent(event); return event.defaultPrevented;
  };
  const { value, chat, sync, scope } = create(); await flushPromises();
  expect(leave()).toBe(false);
  value.value = 'unsent'; expect(sync.unsaved.value).toBe(true); expect(leave()).toBe(true);
  await vi.advanceTimersByTimeAsync(1_000); expect(leave()).toBe(false);
  mocks.put.mockRejectedValueOnce(new Error('network'));
  value.value = 'left behind'; chat.value = 13; await flushPromises();
  expect(sync.problem.value).toBeNull(); expect(sync.unsaved.value).toBe(true); expect(leave()).toBe(true);
  await vi.advanceTimersByTimeAsync(2_000); expect(server.text).toBe('left behind'); expect(leave()).toBe(false);
  mocks.put.mockRejectedValue(new Error('network')); value.value = 'disposed';
  scope.stop(); await flushPromises(); expect(leave()).toBe(false);
});

it('reports local storage failure honestly while offline', async () => {
  const { value, sync } = create(); await flushPromises();
  vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('quota'); });
  vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false); window.dispatchEvent(new Event('offline'));
  value.value = 'not safe'; expect(sync.state.value).toBe('unprotected'); expect(sync.localSaved.value).toBe(false);
});

it('flushes the previous chat without changing the newly opened editor', async () => {
  const { value, chat, sync } = create(); await flushPromises(); value.value = 'old chat';
  const pending = deferred<{ draft: TextDraftSnapshot }>(); mocks.put.mockReturnValueOnce(pending.promise);
  chat.value = 13; await flushPromises(); expect(value.value).toBe(''); value.value = 'new chat';
  pending.resolve({ draft: snapshot('old chat', 1) }); await flushPromises();
  expect(value.value).toBe('new chat'); expect(sync.state.value).toBe('pending');
  expect(JSON.parse(localStorage.getItem('draft.1.12')!).text).toBe('old chat');
});

it('isolates accounts and ignores replies from the previous account', async () => {
  const { value, account } = create(); await flushPromises(); value.value = 'private';
  const pending = deferred<{ draft: TextDraftSnapshot }>(); mocks.put.mockReturnValueOnce(pending.promise);
  await vi.advanceTimersByTimeAsync(1_000); account.value = 2; await flushPromises();
  pending.resolve({ draft: snapshot('private', 1) }); await flushPromises();
  expect(value.value).toBe(''); expect(localStorage.getItem('draft.2.12')).not.toContain('private');
});

it('preserves newer edits after the submitted revision was consumed', async () => {
  const { value, sync } = create(); await flushPromises(); value.value = 'send me';
  const token = await sync.beginSubmission(value.value); expect(token.revision).toBe(1);
  value.value = 'next message'; server = snapshot('', 2); await sync.finishSubmission(token, true); await flushPromises();
  expect(value.value).toBe('next message'); expect(sync.conflict.value).toBeNull();
  expect(server.text).toBe('next message'); expect(server.revision).toBe(3);
});

it('does not treat another device write as the consumed revision', async () => {
  const { value, sync } = create(); await flushPromises(); value.value = 'send me';
  const token = await sync.beginSubmission(value.value); value.value = 'local continuation';
  server = snapshot('remote continuation', 2); await sync.finishSubmission(token, true);
  expect(value.value).toBe('local continuation'); expect(sync.state.value).toBe('conflict');
  expect(server.text).toBe('remote continuation');
});

it('keeps a rejected submission available without clearing the server draft', async () => {
  const { value, sync } = create(); await flushPromises(); value.value = 'retry send';
  const token = await sync.beginSubmission(value.value); await sync.finishSubmission(token, false);
  expect(value.value).toBe('retry send'); expect(server.text).toBe('retry send'); expect(sync.state.value).toBe('saved');
});

it('restores dirty local recovery without blindly applying it over a newer revision', async () => {
  localStorage.setItem('draft.1.12', JSON.stringify({ version: 1, text: 'offline edits', base: snapshot('base', 2), dirty: true }));
  server = snapshot('another device', 3); const { value, sync } = create(); await flushPromises();
  expect(value.value).toBe('offline edits'); expect(sync.state.value).toBe('conflict'); expect(mocks.put).not.toHaveBeenCalled();
});

it('imports a legacy draft only when the caller explicitly authorizes that migration', async () => {
  localStorage.setItem('legacy.12', JSON.stringify({ version: 1, text: 'old local draft' }));
  const scope = effectScope(); scopes.push(scope);
  const value = ref('');
  const sync = scope.run(() => useSyncedTextDraft({ value, target: computed(() => ({
    accountId: 1, key: 'draft.1.12', endpoint: '/drafts/12', legacyKey: 'legacy.12',
  })) }))!;
  await flushPromises();
  expect(value.value).toBe('old local draft'); expect(localStorage.getItem('legacy.12')).toBeNull();
  await sync.flush(); expect(server.text).toBe('old local draft');
});

it('keeps the legacy recovery if account-scoped storage fails', async () => {
  localStorage.setItem('legacy.12', JSON.stringify({ version: 1, text: 'old local draft' }));
  vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('quota'); });
  const scope = effectScope(); scopes.push(scope);
  const value = ref('');
  scope.run(() => useSyncedTextDraft({ value, target: computed(() => ({
    accountId: 1, key: 'draft.1.12', endpoint: '/drafts/12', legacyKey: 'legacy.12',
  })) }));
  await flushPromises();
  expect(value.value).toBe('old local draft'); expect(localStorage.getItem('legacy.12')).not.toBeNull();
});

it('refreshes clean drafts on focus without saving them again', async () => {
  const { value } = create(); await flushPromises(); server = snapshot('from phone', 3);
  window.dispatchEvent(new Event('focus')); await flushPromises();
  expect(value.value).toBe('from phone'); await vi.advanceTimersByTimeAsync(10_000);
  expect(mocks.put).not.toHaveBeenCalled();
});

it('flushes a dirty draft when the editing scope is disposed', async () => {
  const { value, scope } = create(); await flushPromises(); value.value = 'leaving now';
  scope.stop(); await flushPromises(); expect(server.text).toBe('leaving now');
});


it('retries a failed refresh of a previously loaded clean draft', async () => {
  const { value, sync } = create(); await flushPromises();
  mocks.get.mockRejectedValueOnce(new Error('Network unavailable'));
  await sync.refresh(); expect(sync.state.value).toBe('error');
  server = snapshot('From another device', 1);
  await sync.flush();
  expect(value.value).toBe('From another device');
  expect(sync.state.value).toBe('saved');
  expect(mocks.put).not.toHaveBeenCalled();
});

it('syncs dirty inactive chats on reconnect without changing the active editor', async () => {
  const { value, chat } = create(); await flushPromises();
  vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false);
  window.dispatchEvent(new Event('offline'));
  value.value = 'Offline draft in first chat'; chat.value = 13;
  expect(value.value).toBe('');
  vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true);
  window.dispatchEvent(new Event('online')); await flushPromises();
  expect(mocks.put).toHaveBeenCalledWith('/drafts/12', expect.objectContaining({ text: 'Offline draft in first chat' }), expect.anything());
  expect(value.value).toBe('');
});


it('keeps independent tab recovery when a clean tab receives a late snapshot', async () => {
  sessionStorage.setItem('ic.draft.recovery-tab', 'tab-a');
  const a = create(); await flushPromises();
  sessionStorage.setItem('ic.draft.recovery-tab', 'tab-b');
  const b = create(); await flushPromises();
  b.value.value = 'Unsynchronized text in tab B';
  await a.sync.refresh();
  expect(JSON.parse(localStorage.getItem('draft.1.12.recovery.tab-b')!).text).toBe('Unsynchronized text in tab B');
  expect(JSON.parse(localStorage.getItem('draft.1.12')!).text).toBe('Unsynchronized text in tab B');
  a.value.value = 'Independent text in A';
  expect(JSON.parse(localStorage.getItem('draft.1.12.recovery.tab-a')!).text).toBe('Independent text in A');
  const reloadedB = create(); await flushPromises();
  expect(reloadedB.value.value).toBe('Unsynchronized text in tab B');
});


it('continues backing off clean draft read failures until recovery', async () => {
  const { value, sync } = create(); await flushPromises();
  mocks.get.mockRejectedValueOnce(new Error('Offline')).mockRejectedValueOnce(new Error('Still offline'));
  await sync.refresh();
  await vi.advanceTimersByTimeAsync(1_000);
  expect(sync.state.value).toBe('error');
  server = snapshot('Recovered remote text', 1);
  await vi.advanceTimersByTimeAsync(4_000);
  expect(value.value).toBe('Recovered remote text');
  expect(sync.state.value).toBe('saved');
});
