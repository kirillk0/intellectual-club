import { defineComponent, h } from 'vue';
import { mount } from '@vue/test-utils';

class FakeEventSource extends EventTarget {
  static instances: FakeEventSource[] = [];
  closed = false;
  constructor(readonly url: string) {
    super();
    FakeEventSource.instances.push(this);
  }
  close() { this.closed = true; }
  open() { this.dispatchEvent(new Event('open')); }
  fail() { this.dispatchEvent(new Event('error')); }
  message(data: string) {
    this.dispatchEvent(new MessageEvent('chat_state_changed', { data }));
  }
}

describe('chat server invalidations', () => {
  let visibility: DocumentVisibilityState;
  let online: boolean;
  const unsubscribers: Array<() => void> = [];
  const latest = () => FakeEventSource.instances.at(-1)!;

  beforeEach(() => {
    vi.resetModules();
    vi.useFakeTimers();
    FakeEventSource.instances = [];
    visibility = 'visible';
    online = true;
    vi.spyOn(document, 'visibilityState', 'get').mockImplementation(() => visibility);
    vi.spyOn(navigator, 'onLine', 'get').mockImplementation(() => online);
    vi.stubGlobal('EventSource', FakeEventSource);
  });

  afterEach(() => {
    unsubscribers.splice(0).forEach((unsubscribe) => unsubscribe());
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  it('shares one socket and closes it only after the final subscription', async () => {
    const { subscribeChatServerEvents } = await import('@/features/chat/chatServerEvents');
    const first = vi.fn();
    const second = vi.fn();
    const stopFirst = subscribeChatServerEvents(first);
    const stopSecond = subscribeChatServerEvents(second);
    unsubscribers.push(stopFirst, stopSecond);
    expect(FakeEventSource.instances).toHaveLength(1);
    expect(latest().url).toBe('/api/bff/chat-events');
    latest().open();
    expect(first).toHaveBeenCalledWith({ chatId: null });
    expect(second).toHaveBeenCalledWith({ chatId: null });
    latest().message('{"chat_id":42}');
    expect(first).toHaveBeenLastCalledWith({ chatId: 42 });
    stopFirst();
    expect(latest().closed).toBe(false);
    stopSecond();
    expect(latest().closed).toBe(true);
  });

  it('invalidates draft consumers and list subscribers without exposing the draft text', async () => {
    const { subscribeChatServerEvents } = await import('@/features/chat/chatServerEvents');
    const { subscribeChatChanges } = await import('@/features/chat/chatEvents');
    const serverListener = vi.fn();
    const draftListener = vi.fn();
    unsubscribers.push(subscribeChatServerEvents(serverListener), subscribeChatChanges(draftListener));
    latest().dispatchEvent(new MessageEvent('chat_draft_changed', { data: '{"chat_id":42,"revision":7}' }));
    expect(serverListener).toHaveBeenCalledExactlyOnceWith({ chatId: 42, kind: 'draft' });
    expect(draftListener).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({ operation: 'touch', id: 42, meta: { reason: 'draft-changed', revision: 7 } }));
  });

  it('reconciles a new subscriber when a connection is already open', async () => {
    const { subscribeChatServerEvents } = await import('@/features/chat/chatServerEvents');
    unsubscribers.push(subscribeChatServerEvents(vi.fn()));
    latest().open();
    const late = vi.fn();
    unsubscribers.push(subscribeChatServerEvents(late));
    expect(late).toHaveBeenCalledExactlyOnceWith({ chatId: null });
    expect(FakeEventSource.instances).toHaveLength(1);
  });

  it('ignores invalid JSON and nonpositive or unsafe chat IDs', async () => {
    const { subscribeChatServerEvents } = await import('@/features/chat/chatServerEvents');
    const listener = vi.fn();
    unsubscribers.push(subscribeChatServerEvents(listener));
    for (const value of ['bad', 'null', '[]', '{}', '{"chat_id":"42"}', '{"chat_id":0}',
      '{"chat_id":-1}', '{"chat_id":1.2}', '{"chat_id":9007199254740992}']) {
      latest().message(value);
    }
    expect(listener).not.toHaveBeenCalled();
    latest().message('{"chat_id":7}');
    expect(listener).toHaveBeenCalledExactlyOnceWith({ chatId: 7 });
  });

  it('closes in the background and reconciles again after returning', async () => {
    const { subscribeChatServerEvents } = await import('@/features/chat/chatServerEvents');
    const listener = vi.fn();
    unsubscribers.push(subscribeChatServerEvents(listener));
    const old = latest();
    old.open();
    listener.mockClear();
    visibility = 'hidden';
    document.dispatchEvent(new Event('visibilitychange'));
    expect(old.closed).toBe(true);
    old.message('{"chat_id":3}');
    expect(listener).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(FakeEventSource.instances).toHaveLength(1);
    visibility = 'visible';
    document.dispatchEvent(new Event('visibilitychange'));
    expect(FakeEventSource.instances).toHaveLength(2);
    latest().open();
    expect(listener).toHaveBeenCalledExactlyOnceWith({ chatId: null });
  });

  it('backs off on disconnection and cancels retries on final unsubscribe', async () => {
    const { subscribeChatServerEvents } = await import('@/features/chat/chatServerEvents');
    const listener = vi.fn();
    const unsubscribe = subscribeChatServerEvents(listener);
    unsubscribers.push(unsubscribe);
    latest().fail();
    expect(latest().closed).toBe(true);
    await vi.advanceTimersByTimeAsync(999);
    expect(FakeEventSource.instances).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(FakeEventSource.instances).toHaveLength(2);
    latest().fail();
    await vi.advanceTimersByTimeAsync(1_999);
    expect(FakeEventSource.instances).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(FakeEventSource.instances).toHaveLength(3);
    latest().open();
    expect(listener).toHaveBeenLastCalledWith({ chatId: null });
    latest().fail();
    unsubscribe();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(FakeEventSource.instances).toHaveLength(3);
  });

  it('waits for connectivity and never duplicates sockets on wake events', async () => {
    const { subscribeChatServerEvents } = await import('@/features/chat/chatServerEvents');
    online = false;
    unsubscribers.push(subscribeChatServerEvents(vi.fn()));
    expect(FakeEventSource.instances).toHaveLength(0);
    online = true;
    window.dispatchEvent(new Event('online'));
    window.dispatchEvent(new Event('focus'));
    window.dispatchEvent(new Event('pageshow'));
    document.dispatchEvent(new Event('resume'));
    expect(FakeEventSource.instances).toHaveLength(1);
    online = false;
    window.dispatchEvent(new Event('offline'));
    expect(latest().closed).toBe(true);
  });

  it('leaves polling as a safe fallback when EventSource is unavailable', async () => {
    vi.stubGlobal('EventSource', undefined);
    const { subscribeChatServerEvents } = await import('@/features/chat/chatServerEvents');
    unsubscribers.push(subscribeChatServerEvents(vi.fn()));
    window.dispatchEvent(new Event('online'));
    expect(FakeEventSource.instances).toHaveLength(0);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('cleans up a Vue subscription when its owning view unmounts', async () => {
    const { useChatServerEvents } = await import('@/features/chat/chatServerEvents');
    const wrapper = mount(defineComponent({
      setup() {
        useChatServerEvents(vi.fn());
        return () => h('div');
      },
    }));
    expect(FakeEventSource.instances).toHaveLength(1);
    wrapper.unmount();
    expect(latest().closed).toBe(true);
    window.dispatchEvent(new Event('focus'));
    expect(FakeEventSource.instances).toHaveLength(1);
  });
});
