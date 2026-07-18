import { mount } from '@vue/test-utils';
import AppUpdateBanner from '@/components/AppUpdateBanner.vue';

describe('AppUpdateBanner', () => {
  it('shows immediate feedback and prevents repeated update clicks while busy', async () => {
    const wrapper = mount(AppUpdateBanner, {
      props: { updating: false },
    });
    const button = wrapper.get('button');

    expect(button.text()).toBe('Update');
    expect(button.attributes('aria-busy')).toBe('false');
    expect(button.attributes('disabled')).toBeUndefined();

    await button.trigger('click');
    expect(wrapper.emitted('update')).toHaveLength(1);

    await wrapper.setProps({ updating: true });
    expect(button.text()).toBe('Updating…');
    expect(button.attributes('aria-busy')).toBe('true');
    expect(button.attributes('disabled')).toBeDefined();

    await button.trigger('click');
    expect(wrapper.emitted('update')).toHaveLength(1);
  });
});
