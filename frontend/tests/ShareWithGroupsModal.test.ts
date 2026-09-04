import { mount } from '@vue/test-utils';
import { h } from 'vue';

import ShareWithGroupsModal from '@/components/ShareWithGroupsModal.vue';

const ModalStub = {
  emits: ['cancel', 'submit'],
  template: '<div><slot /></div>',
};

describe('ShareWithGroupsModal additional controls', () => {
  it('renders the additional message and action without coupling them to group saving', async () => {
    const exportAction = vi.fn();
    const wrapper = mount(ShareWithGroupsModal, {
      props: {
        open: true,
        groups: [{ id: 1, name: 'Editors' }],
        selectedGroupIds: [],
      },
      slots: {
        'additional-message': '<p class="export-error">Export failed</p>',
        'additional-action': () =>
          h('button', { class: 'export-action', type: 'button', onClick: exportAction }, 'Export HTML'),
      },
      global: { stubs: { ModalWindow: ModalStub } },
    });

    expect(wrapper.get('.export-error').text()).toBe('Export failed');
    await wrapper.get('.export-action').trigger('click');
    await wrapper.get('.primary').trigger('click');

    expect(exportAction).toHaveBeenCalledOnce();
    expect(wrapper.emitted('save')).toEqual([[[]]]);
  });
});
