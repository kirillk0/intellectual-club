import { mount } from '@vue/test-utils';
import ShareToolbarButton from '@/components/ShareToolbarButton.vue';

describe('ShareToolbarButton', () => {
  it('shows the indicator and announces active sharing', () => {
    const wrapper = mount(ShareToolbarButton, {
      props: { shared: true },
    });

    expect(wrapper.find('.share-toolbar-button__indicator').exists()).toBe(true);
    expect(wrapper.get('button').attributes('aria-label')).toBe('Sharing settings. Shared with groups.');
  });

  it('hides the indicator when the item is not shared', () => {
    const wrapper = mount(ShareToolbarButton);

    expect(wrapper.find('.share-toolbar-button__indicator').exists()).toBe(false);
    expect(wrapper.get('button').attributes('aria-label')).toBe('Sharing settings');
  });

  it('forwards clicks', async () => {
    const wrapper = mount(ShareToolbarButton);

    await wrapper.get('button').trigger('click');

    expect(wrapper.emitted('click')).toHaveLength(1);
  });
});
