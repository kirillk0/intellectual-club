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
import CrudHeader from '@/components/CrudHeader.vue';
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
    supports_hosted_web_search: false,
  },
];

const toolTypes = [
  {
    type: 'mcp-http',
    title: 'MCP HTTP',
    description: '',
    functions_mode: 'fixed',
    supports_discovery: false,
    supports_artifacts: false,
    supports_handoff: false,
    config_schema: {
      type: 'object',
      properties: {
        server_url: { type: 'string', title: 'Server URL' },
        open_headers: { type: 'object', 'x-ui': { widget: 'hidden' } },
        secret_header_names: { type: 'array', 'x-ui': { widget: 'hidden' } },
      },
    },
    secrets_schema: {
      type: 'object',
      properties: {
        bearer_token: {
          type: 'string',
          title: 'Bearer token',
        },
        secret_headers: {
          type: 'object',
          title: 'Secret headers',
          'x-ui': { widget: 'hidden' },
        },
      },
    },
    default_config: { server_url: '', open_headers: {}, secret_header_names: [] },
    fixed_functions: [],
  },
];

let activeToolTypes = toolTypes;

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

function editableToolDocument(attributes: Record<string, unknown>) {
  return {
    data: {
      id: '27',
      type: 'tool-instances',
      attributes: {
        name: 'MCP tool',
        description: '',
        alias: 'mcp_tool',
        type: 'mcp-http',
        max_output_tokens: 20_000,
        rps_limit: null,
        secrets_present: ['secret_headers'],
        can_edit: true,
        shared_incoming: false,
        shared_outgoing: false,
        ...attributes,
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
    activeToolTypes = toolTypes;
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
      if (path === '/api/bff/tools/types') return { types: activeToolTypes };
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
        type: 'mcp-http',
        config: {
          server_url: 'https://mcp.example.com',
          open_headers: { 'X-Tenant-ID': 'tenant-42' },
          secret_header_names: ['X-API-Key'],
        },
        max_output_tokens: 20_000,
        rps_limit: null,
        secrets_present: ['secret_headers'],
      })
    );

    const view = await mountView(ToolInstanceEditView, '/catalogs/tools/27');
    await vi.waitFor(() => expect(view.text()).toContain('This tool is read-only.'));

    const openHeaders = view.get('[data-testid="open-headers-editor"]');
    const openHeaderInputs = openHeaders.findAll<HTMLInputElement>('input');
    expect(openHeaderInputs.map((input) => input.element.value)).toEqual(['X-Tenant-ID', 'tenant-42']);
    expect(openHeaders.element.closest('fieldset[disabled]')).not.toBeNull();

    const credentialsTab = tabByText(view, 'Credentials');
    credentialsTab.element.click();
    await nextTick();

    const secretHeaders = view.get('[data-testid="secret-headers-editor"]');
    const secretHeaderInputs = secretHeaders.findAll<HTMLInputElement>('input');
    expect(secretHeaderInputs[0]?.element.value).toBe('X-API-Key');
    expect(secretHeaderInputs[1]?.element.value).toBe('');
    expect(secretHeaderInputs[1]?.attributes('type')).toBe('password');
    expect(secretHeaders.element.closest('fieldset[disabled]')).not.toBeNull();
    expect(secretHeaders.text()).toContain('stored');

    const descriptionTab = tabByText(view, 'Description');
    expect(descriptionTab.element.closest('fieldset[disabled]')).toBeNull();
    expect(view.get<HTMLInputElement>('input.full').element.closest('fieldset[disabled]')).not.toBeNull();

    descriptionTab.element.click();
    await nextTick();
    expect(tabByText(view, 'Description').classes()).toContain('active');
  });

  it('saves MCP open headers and patches secret header values separately', async () => {
    const originalConfig = {
      server_url: 'https://mcp.example.com',
      open_headers: { 'X-Tenant-ID': 'tenant-42' },
      secret_header_names: ['X-Keep', 'X-Remove'],
    };
    jsonApiMocks.get.mockResolvedValue(editableToolDocument({ config: originalConfig }));
    jsonApiMocks.update.mockImplementation(async (_path, _type, _id, attributes) =>
      editableToolDocument(attributes)
    );

    const view = await mountView(ToolInstanceEditView, '/catalogs/tools/27');
    await tabByText(view, 'General').trigger('click');
    await vi.waitFor(() => expect(view.find('[data-testid="open-headers-editor"]').exists()).toBe(true));

    const openInputs = view.get('[data-testid="open-headers-editor"]').findAll<HTMLInputElement>('input');
    await openInputs[1]?.setValue('tenant-84');

    await tabByText(view, 'Credentials').trigger('click');
    let secretEditor = view.get('[data-testid="secret-headers-editor"]');
    const initialSecretRows = secretEditor.findAll('.mcp-header-row');
    await initialSecretRows[1]?.get('button.danger').trigger('click');
    await secretEditor.get('button.mcp-add-header').trigger('click');

    secretEditor = view.get('[data-testid="secret-headers-editor"]');
    const secretInputs = secretEditor.findAll<HTMLInputElement>('input');
    await secretInputs[2]?.setValue('X-New');
    await secretInputs[3]?.setValue('new-secret');

    view.getComponent(CrudHeader).vm.$emit('save');
    await vi.waitFor(() => expect(jsonApiMocks.update).toHaveBeenCalledTimes(1));

    const attributes = jsonApiMocks.update.mock.calls[0]?.[3];
    expect(attributes).toMatchObject({
      config: {
        server_url: 'https://mcp.example.com',
        open_headers: { 'X-Tenant-ID': 'tenant-84' },
        secret_header_names: ['X-Keep', 'X-New'],
      },
      secrets: {
        secret_headers: {
          'X-Remove': '',
          'X-New': 'new-secret',
        },
      },
    });
    expect(attributes.secrets.secret_headers).not.toHaveProperty('X-Keep');
  });

  it('keeps the MCP form populated after discovery when the detail document is unchanged', async () => {
    activeToolTypes = toolTypes.map((toolType) => ({
      ...toolType,
      functions_mode: 'stored',
      supports_discovery: true,
    }));
    const document = editableToolDocument({
      description: 'Discovery regression fixture',
      config: {
        server_url: 'https://mcp.example.com',
        open_headers: { 'X-Tenant-ID': 'tenant-42' },
        secret_header_names: ['X-API-Key'],
      },
    });
    jsonApiMocks.get.mockResolvedValue(document);
    clientMocks.post.mockResolvedValue({
      tool_instance_id: 27,
      created: 0,
      updated: 1,
      deleted: 0,
      total: 1,
      functions: [{ id: 101 }],
    });

    const view = await mountView(ToolInstanceEditView, '/catalogs/tools/27');
    await vi.waitFor(() => expect(view.get<HTMLInputElement>('input.full').element.value).toBe('MCP tool'));
    await tabByText(view, 'Functions').trigger('click');
    await view.get('.tool-discover-button').trigger('click');
    await vi.waitFor(() => expect(clientMocks.post).toHaveBeenCalledTimes(1));
    await flushPromises();

    await tabByText(view, 'General').trigger('click');
    expect(view.get<HTMLInputElement>('input.full').element.value).toBe('MCP tool');
    expect(view.get<HTMLInputElement>('input[type="url"]').element.value).toBe('https://mcp.example.com');
    expect(view.get<HTMLInputElement>('[data-testid="open-headers-editor"] input').element.value).toBe('X-Tenant-ID');
  });

  it('marks the functions tab and discovery button when a saved tool has no functions', async () => {
    activeToolTypes = toolTypes.map((toolType) => ({
      ...toolType,
      functions_mode: 'stored',
      supports_discovery: true,
    }));
    jsonApiMocks.get.mockResolvedValue(editableToolDocument({ config: {} }));

    const view = await mountView(ToolInstanceEditView, '/catalogs/tools/27');
    await vi.waitFor(() => expect(tabByText(view, 'Functions').find('.tool-discovery-warning').exists()).toBe(true));
    expect(view.findAll('.tab').map((tab) => tab.text())).toEqual([
      'General',
      'Credentials',
      '! Functions (0)',
      'Description',
    ]);

    await tabByText(view, 'Functions').trigger('click');
    expect(view.get('.tool-discover-button').find('.tool-discovery-warning').exists()).toBe(true);
    expect(view.findAll('.tool-discovery-warning')).toHaveLength(2);
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
