import { mount } from '@vue/test-utils';
import { nextTick } from 'vue';

import LoadingStatusBanner from '@/components/LoadingStatusBanner.vue';
import { beginLoadTask } from '@/features/app/loadCoordinator';
import { i18n, setPreferredLocale } from '@/i18n';

describe('LoadingStatusBanner', () => {
  afterEach(() => {
    setPreferredLocale(null);
  });

  it('shows a staged, accessible status only for a delayed task', async () => {
    const handle = beginLoadTask({
      key: 'status-test',
      stage: 'route',
      startedAt: Date.now() - 2_100,
    });
    const wrapper = mount(LoadingStatusBanner, { global: { plugins: [i18n] } });

    expect(wrapper.get('[role="status"]').text()).toContain('Loading application');
    expect(wrapper.get('[role="progressbar"]').attributes('aria-valuenow')).toBe('2');
    expect(wrapper.findAll('.loading-status-progress__stage')).toHaveLength(3);

    handle.update({ attempt: 1, retrying: true });
    await nextTick();
    expect(wrapper.text()).toContain('Loading section…');
    expect(wrapper.text()).not.toContain('Retrying');

    handle.update({ attempt: 2, retrying: true });
    await nextTick();
    expect(wrapper.text()).toContain('Retrying… Attempt 2');

    handle.finish();
    await nextTick();
    expect(wrapper.find('[role="status"]').exists()).toBe(false);
    wrapper.unmount();
  });

  it('uses a distinct Russian message for a hidden-tab pause', async () => {
    setPreferredLocale('ru');
    const handle = beginLoadTask({
      key: 'hidden-status-test',
      stage: 'data',
      startedAt: Date.now() - 2_100,
    });
    handle.update({
      waitingForConnection: false,
      waitingForVisibility: true,
    });
    const wrapper = mount(LoadingStatusBanner, { global: { plugins: [i18n] } });

    expect(wrapper.text()).toContain('Загрузка приостановлена, пока вкладка неактивна');

    handle.finish();
    wrapper.unmount();
  });
});
