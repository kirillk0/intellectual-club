import { mount } from '@vue/test-utils';
import WebPushDeviceBanner from '@/components/WebPushDeviceBanner.vue';

describe('WebPushDeviceBanner', () => {
  it('offers to turn a lost subscription back on and blocks repeated clicks while busy', async () => {
    const wrapper = mount(WebPushDeviceBanner, {
      props: { notice: 'lost', enabling: false, error: '' },
    });
    const [enableButton, dismissButton] = wrapper.findAll('button');

    expect(enableButton.text()).toBe('Turn on again');
    await enableButton.trigger('click');
    expect(wrapper.emitted('enable')).toHaveLength(1);

    await wrapper.setProps({ enabling: true, error: 'Notification permission was not granted.' });
    expect(enableButton.text()).toBe('Turning on…');
    expect(enableButton.attributes('disabled')).toBeDefined();
    expect(dismissButton.attributes('disabled')).toBeDefined();
    expect(wrapper.text()).toContain('Notification permission was not granted.');
  });

  it('only explains how to allow notifications when permission is blocked', async () => {
    const wrapper = mount(WebPushDeviceBanner, {
      props: { notice: 'blocked', enabling: false, error: '' },
    });
    const buttons = wrapper.findAll('button');

    expect(buttons).toHaveLength(1);
    expect(wrapper.text()).toContain('Allow notifications for this app');

    await buttons[0].trigger('click');
    expect(wrapper.emitted('dismiss')).toHaveLength(1);
  });
});
