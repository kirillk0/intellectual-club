import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { VueQueryPlugin } from '@tanstack/vue-query';
import { createMemoryHistory, createRouter } from 'vue-router';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(), post: vi.fn(), create: vi.fn(), update: vi.fn(), list: vi.fn(), document: vi.fn(),
}));

vi.mock('@/api/client', async () => ({
  ...await vi.importActual<typeof import('@/api/client')>('@/api/client'),
  api: { get: apiMocks.get, post: apiMocks.post },
}));
vi.mock('@/api/jsonApi', async () => ({
  ...await vi.importActual<typeof import('@/api/jsonApi')>('@/api/jsonApi'),
  jsonApiCreate: apiMocks.create,
  jsonApiUpdate: apiMocks.update,
  jsonApiList: apiMocks.list,
  jsonApiGet: apiMocks.document,
}));

import StackRouterView from '@/components/StackRouterView.vue';
import CrudHeader from '@/components/CrudHeader.vue';
import KnowledgeBlockEditView from '@/views/catalogs/KnowledgeBlockEditView.vue';
import KnowledgeBlockMainFields from '@/features/catalogs/components/knowledge-block/KnowledgeBlockMainFields.vue';
import KnowledgeBlockTabsNav from '@/features/catalogs/components/knowledge-block/KnowledgeBlockTabsNav.vue';
import KnowledgeBlockFilesSection from '@/features/catalogs/components/knowledge-block/KnowledgeBlockFilesSection.vue';
import ManagedSecretsSection from '@/features/catalogs/components/secrets/ManagedSecretsSection.vue';
import { serverStateQueryClient } from '@/features/serverState/queryClient';
import { useNavigationStack } from '@/features/stack/navigationStack';
import type { JsonApiSingleResponse } from '@/api/jsonApi';

let wrapper: VueWrapper;
const records = new Map<number, JsonApiSingleResponse>();
const secrets = new Map<string, unknown[]>();

async function mountEditor() {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{
      path: '/catalogs/knowledge-blocks/:id',
      component: KnowledgeBlockEditView,
      meta: { stackEntityParams: ['id'] },
    }],
  });
  await router.push('/catalogs/knowledge-blocks/new?defaultTagId=7');
  await router.isReady();
  wrapper = mount(StackRouterView, {
    global: {
      plugins: [router, [VueQueryPlugin, { queryClient: serverStateQueryClient }]],
      stubs: {
        CrudHeader: true, RemoteUpdateNotice: true, ShareToolbarButton: true,
        ShareWithGroupsModal: true, KnowledgeBlockDetailsSection: true,
        KnowledgeBlockFilesSection: true, ManagedSecretsSection: true,
        KnowledgeBlockMainFields: true, KnowledgeBlockReadonlyBanner: true,
        KnowledgeBlockTabsNav: true, KnowledgeBlockTagsSection: true,
        KnowledgeBlockCodeEditor: true,
      },
    },
  });
  await flushPromises();
  return router;
}

async function draftSecret(value: string) {
  wrapper.getComponent(KnowledgeBlockMainFields).vm.$emit('update:name', value);
  wrapper.getComponent(KnowledgeBlockTabsNav).vm.$emit('update:modelValue', 'secrets');
  await flushPromises();
  wrapper.getComponent(ManagedSecretsSection).vm.$emit('update:secrets', [{
    id: -1, external_id: 'pending-1', name: value, description: '', env_name: 'TOKEN', value,
  }]);
  await flushPromises();
}

async function save() {
  wrapper.getComponent(CrudHeader).vm.$emit('save');
  await flushPromises();
}

describe('KnowledgeBlockEditView saving related drafts', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    serverStateQueryClient.clear();
    useNavigationStack().reset();
    records.clear();
    secrets.clear();
    vi.spyOn(window, 'alert').mockImplementation(() => {});
    apiMocks.list.mockResolvedValue({ data: [{
      id: '7', type: 'knowledge-tags', attributes: { name: 'Secrets' },
    }] });
    apiMocks.get.mockImplementation(async (path: string) => {
      if (path.endsWith('/secrets')) return { secrets: secrets.get(path) || [] };
      if (path.endsWith('/files')) return { attachments: [] };
      return { groups: [], group_ids: [] };
    });
    apiMocks.create.mockImplementation(async (_path, _type, attributes) => {
      const id = records.size + 1;
      const record: JsonApiSingleResponse = { data: {
        id: String(id), type: 'knowledge-blocks', attributes,
        relationships: { tag_bindings: { data: [{ id: String(id), type: 'knowledge-block-tags' }] } },
      }, included: [{
        id: String(id), type: 'knowledge-block-tags', attributes: { knowledge_tag_id: 7 },
      }] };
      records.set(id, record);
      return record;
    });
    apiMocks.update.mockImplementation(async (_path, _type, id, attributes) => {
      const record = { ...records.get(id)!, data: { ...records.get(id)!.data, attributes } };
      records.set(id, record);
      return record;
    });
    apiMocks.document.mockImplementation(async (path: string) => records.get(Number(path.split('/').at(-1))));
    apiMocks.post.mockImplementation(async (path: string, { value: _value, ...attributes }) => {
      const stored = { id: 10, external_id: 'stored', ...attributes };
      secrets.set(path, [stored]);
      return { secrets: [stored] };
    });
  });

  afterEach(() => {
    wrapper?.unmount();
    serverStateQueryClient.clear();
    useNavigationStack().reset();
  });

  it('saves secrets before remounting and keeps the selected tag for consecutive new blocks', async () => {
    const router = await mountEditor();
    const post = apiMocks.post.getMockImplementation()!;
    apiMocks.post.mockImplementation(async (...args) => {
      expect(router.currentRoute.value.params.id).toBe('new');
      expect(wrapper.getComponent(CrudHeader).props('saving')).toBe(true);
      return post(...args);
    });

    for (const id of [1, 2]) {
      await draftSecret(`Token ${id}`);
      const oldEditor = wrapper.getComponent(KnowledgeBlockEditView).vm;
      await save();
      expect(window.alert).not.toHaveBeenCalled();
      expect(router.currentRoute.value.params.id).toBe(String(id));
      expect(wrapper.getComponent(KnowledgeBlockEditView).vm).not.toBe(oldEditor);
      expect(apiMocks.create).toHaveBeenLastCalledWith(
        '/api/ash/knowledge-blocks', 'knowledge-blocks',
        expect.objectContaining({ content: '', tag_bindings: [{ knowledge_tag_id: 7 }] }),
        expect.any(URLSearchParams)
      );
      expect(apiMocks.post).toHaveBeenLastCalledWith(`/api/bff/knowledge-blocks/${id}/secrets`, {
        name: `Token ${id}`, description: '', env_name: 'TOKEN', value: `Token ${id}`,
      });
      expect(wrapper.getComponent(CrudHeader).props('dirty')).toBe(false);
      if (id === 1) {
        wrapper.getComponent(CrudHeader).vm.$emit('create');
        await flushPromises();
      }
    }
  });

  it('keeps a failed secret draft and retries against the already created block', async () => {
    const router = await mountEditor();
    apiMocks.post.mockRejectedValueOnce(new Error('Secret save failed'));
    vi.spyOn(console, 'error').mockImplementation(() => {});
    await draftSecret('Retry token');
    await save();
    expect(router.currentRoute.value.params.id).toBe('new');
    expect(wrapper.getComponent(ManagedSecretsSection).props('secrets')[0].value).toBe('Retry token');
    expect(wrapper.getComponent(CrudHeader).props('dirty')).toBe(true);

    await save();
    expect(router.currentRoute.value.params.id).toBe('1');
    expect(apiMocks.create).toHaveBeenCalledTimes(1);
    expect(apiMocks.update).toHaveBeenCalledTimes(1);
    expect(apiMocks.post).toHaveBeenCalledTimes(2);
    expect(wrapper.getComponent(CrudHeader).props('dirty')).toBe(false);
  });

  it('uploads files before replacing the new block editor', async () => {
    const router = await mountEditor();
    wrapper.getComponent(KnowledgeBlockTabsNav).vm.$emit('update:modelValue', 'files');
    await flushPromises();
    wrapper.getComponent(KnowledgeBlockFilesSection).vm.$emit('add-files', [new File(['test'], 'test.txt')]);
    apiMocks.post.mockImplementation(async (path: string) => {
      expect(path).toBe('/api/bff/knowledge-blocks/1/files');
      expect(router.currentRoute.value.params.id).toBe('new');
      return { attachments: [] };
    });
    await save();
    expect(apiMocks.post).toHaveBeenCalledTimes(1);
    expect(router.currentRoute.value.params.id).toBe('1');
    expect(window.alert).not.toHaveBeenCalled();
  });
});
