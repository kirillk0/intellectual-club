import { flushPromises, mount } from '@vue/test-utils';
import { VueQueryPlugin } from '@tanstack/vue-query';
import { computed, defineComponent, ref } from 'vue';

const clientMocks = vi.hoisted(() => ({
  get: vi.fn(),
  put: vi.fn(),
}));

vi.mock('@/api/client', async () => {
  const actual = await vi.importActual<typeof import('@/api/client')>('@/api/client');
  return {
    ...actual,
    api: {
      ...actual.api,
      get: clientMocks.get,
      put: clientMocks.put,
    },
  };
});

import { useResourceGroupSharing } from '@/features/catalogs/model/useResourceGroupSharing';
import { serverStateQueryClient } from '@/features/serverState/queryClient';

const SharingHarness = defineComponent({
  setup() {
    const resourceId = ref<number | undefined>(42);
    const sharing = useResourceGroupSharing({
      resourceKey: 'knowledge-block-shares',
      resourceId: computed(() => resourceId.value),
      endpoint: (id) => `/api/bff/knowledge-blocks/${id}/shares`,
      enabled: computed(() => Boolean(resourceId.value)),
      fallbackShared: computed(() => false),
    });

    return { sharing };
  },
  template: `
    <button id="open" type="button" @click="sharing.openModal">Open</button>
    <button id="save" type="button" @click="sharing.save([9])">Save</button>
    <span id="open-state">{{ sharing.modalOpen.value }}</span>
    <span id="groups">{{ sharing.selectedGroupIds.value.join(',') }}</span>
    <span id="shared">{{ sharing.hasOutgoingShares.value }}</span>
  `,
});

describe('useResourceGroupSharing', () => {
  beforeEach(() => {
    serverStateQueryClient.clear();
    clientMocks.get.mockReset().mockImplementation(async (path: string) => {
      if (path === '/api/bff/me/groups') return { groups: [{ id: 9, name: 'Editors' }] };
      if (path === '/api/bff/knowledge-blocks/42/shares') return { group_ids: [9] };
      throw new Error(`Unexpected GET request: ${path}`);
    });
    clientMocks.put.mockReset().mockResolvedValue({ group_ids: [9] });
  });

  afterEach(() => {
    serverStateQueryClient.clear();
  });

  it('loads the selected groups and persists the direct share state', async () => {
    const wrapper = mount(SharingHarness, {
      global: {
        plugins: [[VueQueryPlugin, { queryClient: serverStateQueryClient }]],
      },
    });

    await wrapper.get('#open').trigger('click');
    await flushPromises();

    expect(wrapper.get('#open-state').text()).toBe('true');
    expect(wrapper.get('#groups').text()).toBe('9');
    expect(wrapper.get('#shared').text()).toBe('true');

    await wrapper.get('#save').trigger('click');
    await flushPromises();

    expect(clientMocks.put).toHaveBeenCalledWith(
      '/api/bff/knowledge-blocks/42/shares',
      { group_ids: [9] }
    );
    expect(wrapper.get('#open-state').text()).toBe('false');
    wrapper.unmount();
  });
});
