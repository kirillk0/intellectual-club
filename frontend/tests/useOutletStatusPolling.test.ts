import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { defineComponent, h, ref } from 'vue';

const get = vi.hoisted(() => vi.fn());
vi.mock('@/api/client', () => ({ api: { get } }));

import { useOutletStatusPolling } from '@/features/tools/model/useOutletStatusPolling';

const outlet = (id: number, online = false) => ({ id, type: 'outlet', outlet_online: online });
let wrapper: VueWrapper;

function setup(tools = [outlet(1)]) {
  const params = { scopeId: ref(1), enabled: ref(true), tools: ref(tools) };
  wrapper = mount(defineComponent({
    setup() {
      useOutletStatusPolling(params);
      return () => h('div');
    },
  }));
  return params;
}

describe('outlet status polling', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    get.mockReset();
    get.mockResolvedValue({ tools: [{ id: 1, outlet_online: true }] });
    vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible');
  });

  afterEach(() => {
    wrapper?.unmount();
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  it('refreshes all copies of each outlet every 30 seconds in one batch', async () => {
    const params = setup([outlet(1), outlet(1), { ...outlet(2), type: 'ssh' }]);
    await vi.advanceTimersByTimeAsync(29_999);
    expect(get).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(get).toHaveBeenCalledExactlyOnceWith('/api/bff/tools/status?ids=1', expect.any(Object));
    expect(params.tools.value.map((tool) => tool.outlet_online)).toEqual([true, true, false]);

    get.mockResolvedValue({ tools: [{ id: 1, outlet_online: false }] });
    await vi.advanceTimersByTimeAsync(30_000);
    expect(get).toHaveBeenCalledTimes(2);
    expect(params.tools.value.map((tool) => tool.outlet_online)).toEqual([false, false, false]);
  });

  it('keeps the last status on failure and retries without overlapping requests', async () => {
    const warning = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    let reject!: (reason: Error) => void;
    get.mockImplementationOnce(() => new Promise((_resolve, rejectRequest) => { reject = rejectRequest; }));
    const params = setup([outlet(1, true)]);
    await vi.advanceTimersByTimeAsync(90_000);
    expect(get).toHaveBeenCalledTimes(1);
    reject(new Error('Network unavailable'));
    await flushPromises();
    expect(params.tools.value[0]?.outlet_online).toBe(true);
    expect(warning).toHaveBeenCalledOnce();
    await vi.advanceTimersByTimeAsync(30_000);
    expect(get).toHaveBeenCalledTimes(2);
  });

  it('aborts and ignores a response from the previous chat', async () => {
    let resolve!: (payload: unknown) => void;
    get.mockImplementationOnce(() => new Promise((resolveRequest) => { resolve = resolveRequest; }));
    const params = setup();
    await vi.advanceTimersByTimeAsync(30_000);
    const signal = get.mock.calls[0]?.[1].signal as AbortSignal;
    params.scopeId.value = 2;
    params.tools.value = [outlet(1)];
    await flushPromises();
    expect(signal.aborted).toBe(true);
    resolve({ tools: [{ id: 1, outlet_online: true }] });
    await flushPromises();
    expect(params.tools.value[0]?.outlet_online).toBe(false);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(params.tools.value[0]?.outlet_online).toBe(true);
  });

  it('pauses while hidden or inactive, skips empty targets, and stops on unmount', async () => {
    const visibility = vi.spyOn(document, 'visibilityState', 'get');
    const params = setup();
    visibility.mockReturnValue('hidden');
    document.dispatchEvent(new Event('visibilitychange'));
    await vi.advanceTimersByTimeAsync(60_000);
    expect(get).not.toHaveBeenCalled();

    visibility.mockReturnValue('visible');
    document.dispatchEvent(new Event('visibilitychange'));
    await vi.advanceTimersByTimeAsync(30_000);
    expect(get).toHaveBeenCalledTimes(1);
    params.enabled.value = false;
    await vi.advanceTimersByTimeAsync(60_000);
    expect(get).toHaveBeenCalledTimes(1);
    params.enabled.value = true;
    params.tools.value = [];
    await vi.advanceTimersByTimeAsync(60_000);
    expect(get).toHaveBeenCalledTimes(1);
    params.tools.value = [outlet(1)];
    await vi.advanceTimersByTimeAsync(30_000);
    expect(get).toHaveBeenCalledTimes(2);
    wrapper.unmount();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(get).toHaveBeenCalledTimes(2);
  });
});
