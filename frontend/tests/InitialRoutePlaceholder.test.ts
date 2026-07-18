import { mount, type VueWrapper } from '@vue/test-utils';

const recoveryMocks = vi.hoisted(() => ({
  requestRecoveryNow: vi.fn(),
}));

vi.mock('@/features/app/recoveryHeartbeat', () => recoveryMocks);

import InitialRoutePlaceholder from '@/components/InitialRoutePlaceholder.vue';
import { i18n } from '@/i18n';

describe('InitialRoutePlaceholder', () => {
  let wrapper: VueWrapper | null = null;

  beforeEach(() => {
    vi.useFakeTimers();
    recoveryMocks.requestRecoveryNow.mockReset();
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    vi.useRealTimers();
  });

  it('keeps quick loads quiet and exposes recovery after two seconds', async () => {
    wrapper = mount(InitialRoutePlaceholder, {
      global: {
        plugins: [i18n],
      },
    });

    expect(wrapper.find('[role="status"]').exists()).toBe(false);

    await vi.advanceTimersByTimeAsync(1_999);
    expect(wrapper.find('[role="status"]').exists()).toBe(false);

    await vi.advanceTimersByTimeAsync(1);
    expect(wrapper.get('[role="status"]').text()).toContain('Loading…');

    await wrapper.get('button').trigger('click');
    expect(recoveryMocks.requestRecoveryNow).toHaveBeenCalledOnce();
  });

  it('cancels the pending notice when loading finishes', () => {
    wrapper = mount(InitialRoutePlaceholder, {
      global: {
        plugins: [i18n],
      },
    });

    expect(vi.getTimerCount()).toBe(1);
    wrapper.unmount();
    wrapper = null;
    expect(vi.getTimerCount()).toBe(0);
  });
});
