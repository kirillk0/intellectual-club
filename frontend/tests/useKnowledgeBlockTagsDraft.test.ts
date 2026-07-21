import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
import { defineComponent, h, nextTick, ref } from 'vue';

const jsonApiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  list: vi.fn(),
}));

vi.mock('@/api/jsonApi', async () => {
  const actual = await vi.importActual<typeof import('@/api/jsonApi')>('@/api/jsonApi');
  return {
    ...actual,
    jsonApiGet: jsonApiMocks.get,
    jsonApiList: jsonApiMocks.list,
  };
});

import { useKnowledgeBlockTagsDraft } from '@/features/catalogs/model/useKnowledgeBlockTagsDraft';

const tagResource = {
  id: '7',
  type: 'knowledge-tags',
  attributes: { name: 'Filtered tag', full_name: 'Filtered tag', parent_id: null },
};

function knowledgeBlockDocument() {
  return {
    data: {
      id: '42',
      type: 'knowledge-blocks',
      attributes: {},
      relationships: {
        tag_bindings: { data: [{ id: '70', type: 'knowledge-block-tags' }] },
      },
    },
    included: [
      {
        id: '70',
        type: 'knowledge-block-tags',
        attributes: {},
        relationships: {
          knowledge_tag: { data: { id: '7', type: 'knowledge-tags' } },
        },
      },
      tagResource,
    ],
  };
}

describe('useKnowledgeBlockTagsDraft', () => {
  let wrapper: VueWrapper | null = null;
  let queryClient: QueryClient | null = null;

  beforeEach(() => {
    jsonApiMocks.get.mockReset().mockResolvedValue({ data: tagResource });
    jsonApiMocks.list.mockReset().mockResolvedValue({ data: [tagResource] });
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    queryClient?.clear();
    queryClient = null;
  });

  it('reapplies the filtered tag without reusing the previous block binding', async () => {
    const isNew = ref(true);
    const defaultTagId = ref(7);
    let draft!: ReturnType<typeof useKnowledgeBlockTagsDraft>;
    queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });

    const Harness = defineComponent({
      setup() {
        draft = useKnowledgeBlockTagsDraft({ isNew, defaultTagId });
        return () => h('div');
      },
    });

    wrapper = mount(Harness, {
      global: { plugins: [[VueQueryPlugin, { queryClient }]] },
    });
    await flushPromises();

    expect(draft.attachedTagIds.value).toEqual([7]);
    expect(draft.tagBindingsPayload.value).toEqual([{ knowledge_tag_id: 7 }]);

    isNew.value = false;
    draft.applyDocument(knowledgeBlockDocument());
    await nextTick();
    expect(draft.attachedTagIds.value).toEqual([7]);
    expect(draft.tagBindingsPayload.value).toBeUndefined();

    isNew.value = true;
    await nextTick();
    expect(draft.attachedTagIds.value).toEqual([7]);
    expect(draft.tagBindingsPayload.value).toEqual([{ knowledge_tag_id: 7 }]);
  });
});
