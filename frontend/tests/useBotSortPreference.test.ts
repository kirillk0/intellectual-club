import { enableAutoUnmount, mount } from '@vue/test-utils';
import type { MockInstance } from 'vitest';
import { defineComponent, h, nextTick } from 'vue';

const lifecycle = vi.hoisted(() => ({
  ownerIds: [] as Array<number | null>,
  stops: [] as Array<() => void>,
}));

vi.mock('vue', async (importOriginal) => {
  const vue = await importOriginal<typeof import('vue')>();
  return {
    ...vue,
    watch: (...args: Parameters<typeof vue.watch>) => {
      lifecycle.ownerIds.push(vue.getCurrentInstance()?.uid ?? null);
      const stop = vue.watch(...args);
      lifecycle.stops.push(stop);
      return stop;
    },
  };
});

enableAutoUnmount(afterEach);

const storageKey = 'ic.bots.sort_mode.v1';

describe('bot sort preference', () => {
  let listenerSpy: MockInstance<typeof window.addEventListener>;

  beforeEach(() => {
    vi.resetModules();
    localStorage.clear();
    lifecycle.ownerIds.length = 0;
    listenerSpy = vi.spyOn(window, 'addEventListener');
  });

  afterEach(() => {
    for (const stop of lifecycle.stops.splice(0)) stop();
    for (const [type, listener, options] of listenerSpy.mock.calls) {
      window.removeEventListener(type, listener, options);
    }
    localStorage.clear();
  });

  it('keeps shared persistence independent of the first consumer component', async () => {
    const { useBotSortPreference } = await import('@/features/bots/model/useBotSortPreference');
    let firstMode!: ReturnType<typeof useBotSortPreference>;
    const first = mount(defineComponent({
      setup() {
        firstMode = useBotSortPreference();
        return () => h('div', firstMode.value);
      },
    }));

    // A detached effect scope alone does not prevent watch from retaining currentInstance.
    expect(lifecycle.ownerIds).toEqual([null]);

    const sharedMode = useBotSortPreference();
    expect(sharedMode).toBe(firstMode);
    sharedMode.value = 'recent_activity';
    await nextTick();
    expect(first.text()).toBe('recent_activity');
    expect(localStorage.getItem(storageKey)).toBe('recent_activity');

    first.unmount();
    sharedMode.value = 'name';
    await nextTick();
    expect(localStorage.getItem(storageKey)).toBe('name');
  });

  it.each([
    [null, 'name'],
    ['name', 'name'],
    ['recent_activity', 'recent_activity'],
    ['invalid', 'name'],
  ])('restores %s as %s', async (stored, expected) => {
    if (stored !== null) localStorage.setItem(storageKey, stored);
    const { useBotSortPreference } = await import('@/features/bots/model/useBotSortPreference');

    expect(useBotSortPreference().value).toBe(expected);
  });

  it('synchronizes changes from other tabs and normalizes missing or invalid values', async () => {
    const { useBotSortPreference } = await import('@/features/bots/model/useBotSortPreference');
    const mode = useBotSortPreference();

    for (const value of ['recent_activity', null, 'recent_activity', 'invalid']) {
      window.dispatchEvent(new StorageEvent('storage', { key: storageKey, newValue: value }));
      await nextTick();
      expect(mode.value).toBe(value === 'recent_activity' ? 'recent_activity' : 'name');
    }

    window.dispatchEvent(new StorageEvent('storage', { key: 'unrelated', newValue: 'recent_activity' }));
    expect(mode.value).toBe('name');
  });

  it('remains usable when storage reads and writes fail', async () => {
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new Error('Storage unavailable');
    });
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new Error('Storage unavailable');
    });
    const { useBotSortPreference } = await import('@/features/bots/model/useBotSortPreference');
    const mode = useBotSortPreference();

    expect(mode.value).toBe('name');
    mode.value = 'recent_activity';
    await nextTick();
    expect(mode.value).toBe('recent_activity');
  });
});
