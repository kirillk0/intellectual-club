import { flushPromises, shallowMount, type VueWrapper } from '@vue/test-utils';
import { VueQueryPlugin } from '@tanstack/vue-query';
import { nextTick, type Component } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

const jsonApiMocks = vi.hoisted(() => ({
  create: vi.fn(),
  delete: vi.fn(),
  get: vi.fn(),
  list: vi.fn(),
  update: vi.fn(),
}));

const clientMocks = vi.hoisted(() => ({
  get: vi.fn(),
  patch: vi.fn(),
  post: vi.fn(),
  put: vi.fn(),
}));

const knowledgeBlockFileMocks = vi.hoisted(() => ({
  delete: vi.fn(),
  list: vi.fn(),
  update: vi.fn(),
  upload: vi.fn(),
}));

vi.mock('@/api/client', async () => {
  const actual = await vi.importActual<typeof import('@/api/client')>('@/api/client');
  return {
    ...actual,
    api: {
      ...actual.api,
      get: clientMocks.get,
      patch: clientMocks.patch,
      post: clientMocks.post,
      put: clientMocks.put,
    },
  };
});

vi.mock('@/api/jsonApi', async () => {
  const actual = await vi.importActual<typeof import('@/api/jsonApi')>('@/api/jsonApi');
  return {
    ...actual,
    jsonApiCreate: jsonApiMocks.create,
    jsonApiDelete: jsonApiMocks.delete,
    jsonApiGet: jsonApiMocks.get,
    jsonApiList: jsonApiMocks.list,
    jsonApiUpdate: jsonApiMocks.update,
  };
});

vi.mock('@/api/knowledgeBlockFiles', async () => {
  const actual = await vi.importActual<typeof import('@/api/knowledgeBlockFiles')>('@/api/knowledgeBlockFiles');
  return {
    ...actual,
    deleteKnowledgeBlockFile: knowledgeBlockFileMocks.delete,
    listKnowledgeBlockFiles: knowledgeBlockFileMocks.list,
    updateKnowledgeBlockFile: knowledgeBlockFileMocks.update,
    uploadKnowledgeBlockFile: knowledgeBlockFileMocks.upload,
  };
});

import KnowledgeBlockDetailsSection from '@/features/catalogs/components/knowledge-block/KnowledgeBlockDetailsSection.vue';
import KnowledgeBlockMainFields from '@/features/catalogs/components/knowledge-block/KnowledgeBlockMainFields.vue';
import KnowledgeBlockTabsNav from '@/features/catalogs/components/knowledge-block/KnowledgeBlockTabsNav.vue';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { serverStateQueryClient } from '@/features/serverState/queryClient';
import KnowledgeBlockEditView from '@/views/catalogs/KnowledgeBlockEditView.vue';
import LlmProviderEditView from '@/views/catalogs/LlmProviderEditView.vue';
import ToolInstanceEditView from '@/views/catalogs/ToolInstanceEditView.vue';

const providerTypes = [
  {
    type: 'test-provider',
    label: 'Test provider',
    default_auth_method: 'api_key',
    auth_methods: [{ value: 'api_key', label: 'API key', credential: 'api_key' }],
    base_url_options: [],
    default_base_url: null,
    supports_model_discovery: false,
  },
];

const toolTypes = [
  {
    type: 'test-tool',
    title: 'Test tool',
    description: '',
    functions_mode: 'fixed',
    supports_discovery: false,
    supports_artifacts: false,
    supports_handoff: false,
    config_schema: { type: 'object', properties: {} },
    secrets_schema: null,
    default_config: {},
    fixed_functions: [],
  },
];

function readonlyDocument(type: string, attributes: Record<string, unknown>) {
  return {
    data: {
      id: '27',
      type,
      attributes: {
        ...attributes,
        can_edit: false,
        shared_incoming: true,
        shared_outgoing: false,
      },
      relationships: {
        functions: { data: [] },
        tag_bindings: { data: [] },
      },
    },
    included: [],
  };
}

let wrapper: VueWrapper | null = null;

async function mountView(component: Component, path: string) {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/catalogs/knowledge-blocks/:id', component: { template: '<div />' } },
      { path: '/catalogs/llm-providers/:id', component: { template: '<div />' } },
      { path: '/catalogs/tools/:id', component: { template: '<div />' } },
    ],
  });
  await router.push(path);
  await router.isReady();

  wrapper = shallowMount(component, {
    global: {
      plugins: [router, [VueQueryPlugin, { queryClient: serverStateQueryClient }]],
    },
  });
  await flushPromises();
  return wrapper;
}

function tabByText(view: VueWrapper, text: string) {
  const tab = view.findAll<HTMLButtonElement>('.tab').find((item) => item.text().includes(text));
  if (!tab) throw new Error(`Tab not found: ${text}`);
  return tab;
}

describe('shared read-only editor tabs', () => {
  beforeEach(() => {
    serverStateQueryClient.clear();
    useNavigationStack().reset();
    jsonApiMocks.create.mockReset();
    jsonApiMocks.delete.mockReset();
    jsonApiMocks.get.mockReset();
    jsonApiMocks.list.mockReset().mockResolvedValue({ data: [] });
    jsonApiMocks.update.mockReset();
    knowledgeBlockFileMocks.delete.mockReset();
    knowledgeBlockFileMocks.list.mockReset().mockResolvedValue({ attachments: [] });
    knowledgeBlockFileMocks.update.mockReset();
    knowledgeBlockFileMocks.upload.mockReset();
    clientMocks.get.mockReset().mockImplementation(async (path: string) => {
      if (path === '/api/bff/llm-provider-types') return { types: providerTypes };
      if (path === '/api/bff/tools/types') return { types: toolTypes };
      if (path === '/api/bff/me/groups') return { groups: [] };
      if (path.endsWith('/shares')) return { group_ids: [] };
      throw new Error(`Unexpected GET request: ${path}`);
    });
    clientMocks.patch.mockReset();
    clientMocks.post.mockReset();
    clientMocks.put.mockReset();
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    serverStateQueryClient.clear();
    useNavigationStack().reset();
  });

  it('switches LLM provider tabs while keeping its fields disabled', async () => {
    jsonApiMocks.get.mockResolvedValue(
      readonlyDocument('llm-providers', {
        name: 'Shared provider',
        type: 'test-provider',
        auth_method: 'api_key',
        base_url: 'https://example.com',
        credentials_present: ['api_key'],
      })
    );

    const view = await mountView(LlmProviderEditView, '/catalogs/llm-providers/27');
    await vi.waitFor(() => expect(view.text()).toContain('This provider is read-only.'));

    const credentialsTab = tabByText(view, 'Credentials');
    expect(credentialsTab.element.closest('fieldset[disabled]')).toBeNull();
    expect(view.get<HTMLInputElement>('input.full').element.closest('fieldset[disabled]')).not.toBeNull();

    credentialsTab.element.click();
    await nextTick();
    expect(tabByText(view, 'Credentials').classes()).toContain('active');
  });

  it('switches tool tabs while keeping its fields disabled', async () => {
    jsonApiMocks.get.mockResolvedValue(
      readonlyDocument('tool-instances', {
        name: 'Shared tool',
        description: 'Description',
        alias: 'shared_tool',
        type: 'test-tool',
        config: {},
        max_output_tokens: 20_000,
        rps_limit: null,
        secrets_present: [],
      })
    );

    const view = await mountView(ToolInstanceEditView, '/catalogs/tools/27');
    await vi.waitFor(() => expect(view.text()).toContain('This tool is read-only.'));

    const descriptionTab = tabByText(view, 'Description');
    expect(descriptionTab.element.closest('fieldset[disabled]')).toBeNull();
    expect(view.get<HTMLInputElement>('input.full').element.closest('fieldset[disabled]')).not.toBeNull();

    descriptionTab.element.click();
    await nextTick();
    expect(tabByText(view, 'Description').classes()).toContain('active');
  });

  it('switches knowledge block tabs while keeping its fields disabled', async () => {
    jsonApiMocks.get.mockResolvedValue(
      readonlyDocument('knowledge-blocks', {
        name: 'Shared block',
        version: '1',
        content: 'Read-only content',
        image: null,
        external_id: 'shared-block',
        token_count: 10,
      })
    );

    const view = await mountView(KnowledgeBlockEditView, '/catalogs/knowledge-blocks/27');
    await vi.waitFor(() => expect(view.findComponent(KnowledgeBlockTabsNav).exists()).toBe(true));

    const tabs = view.getComponent(KnowledgeBlockTabsNav);
    expect(tabs.element.closest('fieldset[disabled]')).toBeNull();
    expect(view.getComponent(KnowledgeBlockMainFields).element.closest('fieldset[disabled]')).not.toBeNull();

    tabs.vm.$emit('update:modelValue', 'details');
    await nextTick();
    expect(view.findComponent(KnowledgeBlockDetailsSection).exists()).toBe(true);
  });
});
