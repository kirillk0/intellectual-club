import { effectScope, nextTick, ref, type EffectScope } from 'vue';

import { useDelayedVisibility } from '@/features/app/delayedVisibility';

describe('useDelayedVisibility', () => {
  let scope: EffectScope | null = null;

  beforeEach(() => {
    vi.useFakeTimers();
    scope = effectScope();
  });

  afterEach(() => {
    scope?.stop();
    scope = null;
    vi.useRealTimers();
  });

  it('shows terminal states immediately and stays visible while the same load retries', async () => {
    const active = ref(true);
    const showImmediately = ref(true);
    const visible = scope!.run(() =>
      useDelayedVisibility(active, { showImmediately })
    )!;

    expect(visible.value).toBe(true);

    showImmediately.value = false;
    await nextTick();
    expect(visible.value).toBe(true);
    expect(vi.getTimerCount()).toBe(0);

    active.value = false;
    await nextTick();
    expect(visible.value).toBe(false);

    active.value = true;
    await nextTick();
    expect(visible.value).toBe(false);

    await vi.advanceTimersByTimeAsync(2_000);
    expect(visible.value).toBe(true);
  });
});
