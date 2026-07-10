import { flushPromises, shallowMount } from '@vue/test-utils';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
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

import KnowledgeBlocksIndexView from '@/views/catalogs/KnowledgeBlocksIndexView.vue';

type PendingRequest = {
  params: URLSearchParams;
  signal?: AbortSignal;
  resolve: (payload: { data: [] }) => void;
};

describe('KnowledgeBlocksIndexView server filters', () => {
  beforeEach(() => {
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
    vi.unstubAllGlobals();
  });

  it('keys tag filters separately and aborts requests for superseded filters', async () => {
    const requests: PendingRequest[] = [];
    apiMocks.jsonApiList.mockImplementation(
      (_path: string, params: URLSearchParams, options?: { signal?: AbortSignal }) =>
        new Promise<{ data: [] }>((resolve, reject) => {
          const request = { params, signal: options?.signal, resolve };
          requests.push(request);
          options?.signal?.addEventListener(
            'abort',
            () => reject(new DOMException('The operation was aborted.', 'AbortError')),
            { once: true }
          );
        })
    );

    const router = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/catalogs/knowledge-blocks', component: { template: '<div />' } }],
    });
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    await router.push('/catalogs/knowledge-blocks');
    await router.isReady();

    const wrapper = shallowMount(KnowledgeBlocksIndexView, {
      global: {
        plugins: [router, [VueQueryPlugin, { queryClient }]],
      },
    });

    await vi.waitFor(() => expect(requests).toHaveLength(1));
    expect(requests[0]?.params.get('tag_id')).toBeNull();

    await router.replace({ query: { tag: '7' } });
    await vi.waitFor(() => expect(requests).toHaveLength(2));
    expect(requests[0]?.signal?.aborted).toBe(true);
    expect(requests[1]?.params.get('tag_id')).toBe('7');
    expect(requests[1]?.params.get('no_tags')).toBeNull();

    await router.replace({ query: { no_tags: 'true' } });
    await vi.waitFor(() => expect(requests).toHaveLength(3));
    expect(requests[1]?.signal?.aborted).toBe(true);
    expect(requests[2]?.params.get('tag_id')).toBeNull();
    expect(requests[2]?.params.get('no_tags')).toBe('true');

    expect(queryClient.getQueryCache().getAll().map((query) => query.queryKey)).toContainEqual([
      'server-state',
      'knowledge-blocks',
      'collection',
      'index',
      { q: '', tagId: null, noTags: true },
    ]);

    requests[2]?.resolve({ data: [] });
    await flushPromises();
    wrapper.unmount();
    queryClient.clear();
  });
});
