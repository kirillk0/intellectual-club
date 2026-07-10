import { flushPromises, mount } from '@vue/test-utils';
import { VueQueryPlugin } from '@tanstack/vue-query';
import { createMemoryHistory, createRouter } from 'vue-router';

const apiMocks = vi.hoisted(() => ({
  jsonApiList: vi.fn(),
}));

vi.mock('@/api/jsonApi', async () => {
  const actual = await vi.importActual<typeof import('@/api/jsonApi')>('@/api/jsonApi');
  return {
    ...actual,
    jsonApiList: apiMocks.jsonApiList,
  };
});

import LlmConfigurationsIndexView from '@/views/catalogs/LlmConfigurationsIndexView.vue';
import {
  SERVER_STATE_QUERY_ROOT,
  serverStateQueryClient,
} from '@/features/serverState/queryClient';

describe('LlmConfigurationsIndexView atomic snapshots', () => {
  beforeEach(() => {
    serverStateQueryClient.clear();
    apiMocks.jsonApiList.mockReset();
    vi.stubGlobal(
      'matchMedia',
      vi.fn(() => ({
        matches: false,
        media: '',
        onchange: null,
        addListener: vi.fn(),
        removeListener: vi.fn(),
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
        dispatchEvent: vi.fn(),
      }))
    );
  });

  afterEach(() => {
    serverStateQueryClient.clear();
    vi.unstubAllGlobals();
  });

  it('removes a row under an active tag filter when its last tag is removed', async () => {
    let tagged = true;
    apiMocks.jsonApiList.mockImplementation(async (path: string) => {
      if (path === '/api/ash/llm-configurations') {
        return {
          data: [
            {
              id: '27',
              type: 'llm-configurations',
              attributes: {
                model_name: 'test-model',
                note: '',
                enabled: true,
                provider_id: 4,
              },
            },
          ],
        };
      }

      if (path === '/api/ash/llm-providers') {
        return {
          data: [{ id: '4', type: 'llm-providers', attributes: { name: 'Provider' } }],
        };
      }

      if (path === '/api/ash/llm-configuration-tag-bindings') {
        return tagged
          ? {
              data: [
                {
                  id: '11',
                  type: 'llm-configuration-tag-bindings',
                  attributes: { llm_configuration_id: 27, llm_configuration_tag_id: 9 },
                },
              ],
              included: [
                {
                  id: '9',
                  type: 'llm-configuration-tags',
                  attributes: { name: 'Only tag' },
                },
              ],
            }
          : { data: [], included: [] };
      }

      throw new Error(`Unexpected list request: ${path}`);
    });

    const router = createRouter({
      history: createMemoryHistory(),
      routes: [
        {
          path: '/catalogs/llm-configurations',
          component: { template: '<div />' },
        },
      ],
    });
    await router.push('/catalogs/llm-configurations?tag=9');
    await router.isReady();

    const wrapper = mount(LlmConfigurationsIndexView, {
      global: {
        plugins: [
          router,
          [VueQueryPlugin, { queryClient: serverStateQueryClient }],
        ],
        stubs: {
          StackToolbarTeleport: { template: '<div><slot /></div>' },
          PullToRefresh: { template: '<div><slot /></div>' },
          LlmConfigurationNav: true,
          LlmConfigurationTagsManagerPanel: true,
          SvgIcon: true,
        },
      },
    });

    await vi.waitFor(() => expect(wrapper.text()).toContain('Only tag'));
    expect(wrapper.text()).toContain('test-model');

    tagged = false;
    await serverStateQueryClient.invalidateQueries({
      queryKey: SERVER_STATE_QUERY_ROOT,
      refetchType: 'active',
    });
    await flushPromises();

    expect(wrapper.text()).not.toContain('Only tag');
    expect(wrapper.text()).not.toContain('test-model');
    expect(wrapper.text()).toContain('No configurations found.');

    wrapper.unmount();
  });
});
