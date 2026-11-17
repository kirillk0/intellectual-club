import { flushPromises, shallowMount, type VueWrapper } from '@vue/test-utils';
import { VueQueryPlugin } from '@tanstack/vue-query';
import { createMemoryHistory, createRouter } from 'vue-router';

const jsonApiMocks = vi.hoisted(() => ({
  create: vi.fn(),
  get: vi.fn(),
  list: vi.fn(),
  update: vi.fn(),
}));
const clientMocks = vi.hoisted(() => ({
  get: vi.fn(),
  patch: vi.fn(),
  post: vi.fn(),
}));

vi.mock('@/api/client', async () => {
  const actual = await vi.importActual<typeof import('@/api/client')>('@/api/client');
  return { ...actual, api: { ...actual.api, ...clientMocks } };
});
vi.mock('@/api/jsonApi', async () => {
  const actual = await vi.importActual<typeof import('@/api/jsonApi')>('@/api/jsonApi');
  return {
    ...actual,
    jsonApiCreate: jsonApiMocks.create,
    jsonApiGet: jsonApiMocks.get,
    jsonApiList: jsonApiMocks.list,
    jsonApiUpdate: jsonApiMocks.update,
  };
});

import { HttpError } from '@/api/client';
import CrudHeader from '@/components/CrudHeader.vue';
import RemoteUpdateNotice from '@/components/RemoteUpdateNotice.vue';
import ToolTypeBadge from '@/components/ToolTypeBadge.vue';
import LuaToolSettings from '@/features/tools/components/LuaToolSettings.vue';
import ManagedSecretsSection from '@/features/catalogs/components/secrets/ManagedSecretsSection.vue';
import { toolTypeIconName, toolTypeLabel } from '@/features/tools/model/toolInstances';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { serverStateKeys, serverStateQueryClient } from '@/features/serverState/queryClient';
import { setPreferredLocale, translate } from '@/i18n';
import { messages, ruMessages } from '@/i18n/messages';
import ToolInstanceEditView from '@/views/catalogs/ToolInstanceEditView.vue';

const defaultConfig = {
  source: '-- Example supplied by server metadata\nreturn { counter = function() return { count = 1 } end }\n',
  manifest: {
    functions: [{
      name: 'counter',
      description: 'Read the counter',
      input_schema: { type: 'object', properties: {}, additionalProperties: false },
    }],
    permissions: { http: [] },
  },
};

const luaMetadata = {
  type: 'lua',
  title: 'Lua',
  description: 'Run small Lua tools with per-chat-family state and explicitly allowed HTTP access.',
  functions_mode: 'fixed',
  supports_discovery: false,
  supports_artifacts: false,
  supports_handoff: false,
  config_schema: {
    type: 'object',
    required: ['source', 'manifest'],
    properties: {
      source: { type: 'string', title: 'Lua source' },
      manifest: { type: 'object', title: 'Manifest JSON' },
    },
  },
  secrets_schema: null,
  default_config: defaultConfig,
  fixed_functions: [],
};
const mcpMetadata = {
  ...luaMetadata,
  type: 'mcp-http',
  title: 'MCP HTTP',
  functions_mode: 'stored',
  supports_discovery: true,
  config_schema: { type: 'object', properties: {} },
  secrets_schema: { type: 'object', properties: { secret_headers: { type: 'object' } } },
  default_config: { server_url: 'https://mcp.example.com', open_headers: {}, secret_header_names: [] },
};

function toolDocument(attributes: Record<string, unknown> = {}) {
  return {
    data: {
      id: '27',
      type: 'tool-instances',
      attributes: {
        name: 'Lua counter',
        description: '',
        alias: 'lua_counter',
        type: 'lua',
        config: structuredClone(defaultConfig),
        max_output_tokens: 20_000,
        rps_limit: null,
        can_edit: true,
        shared_incoming: false,
        shared_outgoing: false,
        secrets_present: [],
        ...attributes,
      },
      relationships: { functions: { data: [] } },
    },
    included: [],
  };
}

let document = toolDocument();
let wrapper: VueWrapper | null = null;

async function mountEditor(id = '27') {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/catalogs/tools/:id', component: { template: '<div />' } }],
  });
  await router.push(`/catalogs/tools/${id}`);
  await router.isReady();
  wrapper = shallowMount(ToolInstanceEditView, {
    global: {
      plugins: [router, [VueQueryPlugin, { queryClient: serverStateQueryClient }]],
      stubs: { LuaToolSettings: false, ToolTypeSelect: false, ToolTypeBadge: false },
    },
  });
  await flushPromises();
  await tab(wrapper, 'General').trigger('click');
  return wrapper;
}

function tab(view: VueWrapper, text: string) {
  const match = view.findAll('.tab').find((item) => item.text().includes(text));
  if (!match) throw new Error(`Tab not found: ${text}`);
  return match;
}

function source(view: VueWrapper) {
  return view.get<HTMLTextAreaElement>('[data-testid="lua-source"]');
}

function manifest(view: VueWrapper) {
  return view.get<HTMLTextAreaElement>('[data-testid="lua-manifest"]');
}

async function save(view: VueWrapper) {
  view.getComponent(CrudHeader).vm.$emit('save');
  await flushPromises();
}

beforeEach(() => {
  setPreferredLocale('en');
  vi.spyOn(window, 'alert').mockImplementation(() => undefined);
  vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
  document = toolDocument();
  serverStateQueryClient.clear();
  useNavigationStack().reset();
  jsonApiMocks.get.mockReset().mockImplementation(async () => JSON.parse(JSON.stringify(document)));
  jsonApiMocks.list.mockReset().mockResolvedValue({ data: [] });
  jsonApiMocks.create.mockReset().mockImplementation(async (_path, _type, attributes) => {
    document = toolDocument(attributes);
    return JSON.parse(JSON.stringify(document));
  });
  jsonApiMocks.update.mockReset().mockImplementation(async (_path, _type, _id, attributes) => {
    document = toolDocument(attributes);
    return JSON.parse(JSON.stringify(document));
  });
  clientMocks.get.mockReset().mockImplementation(async (path: string) => {
    if (path === '/api/bff/tools/types') return { types: [mcpMetadata, luaMetadata] };
    if (path.endsWith('/secrets')) {
      return { secrets: [{ id: 1, external_id: 'secret-1', name: 'API token', description: '', env_name: 'API_TOKEN' }] };
    }
    if (path.endsWith('/shares')) return { group_ids: [] };
    if (path === '/api/bff/me/groups') return { groups: [] };
    throw new Error(`Unexpected GET: ${path}`);
  });
  clientMocks.patch.mockReset();
  clientMocks.post.mockReset();
});

afterEach(() => {
  wrapper?.unmount();
  wrapper = null;
  serverStateQueryClient.clear();
  useNavigationStack().reset();
  setPreferredLocale(null);
});

describe('Lua tool editor', () => {
  it('uses server defaults when selecting Lua and creates it without discovery or leftover MCP settings', async () => {
    const view = await mountEditor('new');
    await view.get('.tool-type-select__trigger').trigger('click');
    const option = view.findAll('[role="option"]').find((item) => item.text() === 'Lua')!;
    await option.trigger('click');
    expect(source(view).element.value).toBe(defaultConfig.source);
    expect(JSON.parse(manifest(view).element.value)).toEqual(defaultConfig.manifest);
    expect(view.text()).not.toContain('Advanced JSON');
    expect(view.text()).not.toContain('Unsupported field type');
    expect(view.text()).not.toContain('No additional settings');
    expect(view.text()).toContain(luaMetadata.description);
    expect(tab(view, 'Functions').text()).toContain('(1)');
    expect(tab(view, 'Secrets').exists()).toBe(true);

    await view.get('input.full').setValue('New Lua tool');
    await save(view);
    expect(jsonApiMocks.create).toHaveBeenCalledTimes(1);
    expect(jsonApiMocks.create.mock.calls[0]![2]).toMatchObject({ type: 'lua', config: defaultConfig });
    expect(jsonApiMocks.create.mock.calls[0]![2].config).toEqual(defaultConfig);
    expect(clientMocks.post).not.toHaveBeenCalled();
    expect(clientMocks.patch).not.toHaveBeenCalled();
    expect(window.alert).not.toHaveBeenCalled();
    expect(view.getComponent(CrudHeader).props('dirty')).toBe(false);
  });

  it('does not carry MCP header credentials into a new Lua tool', async () => {
    const view = await mountEditor('new');
    await view.get('input.full').setValue('New Lua tool');
    await tab(view, 'Credentials').trigger('click');
    await view.get('[data-testid="secret-headers-editor"] .mcp-add-header').trigger('click');
    const headerInputs = view.get('[data-testid="secret-headers-editor"]').findAll('input');
    await headerInputs[0]!.setValue('X-API-Key');
    await headerInputs[1]!.setValue('old-mcp-secret');
    await view.get('.tool-type-select__trigger').trigger('click');
    await view.findAll('[role="option"]').find((item) => item.text() === 'Lua')!.trigger('click');
    await tab(view, 'General').trigger('click');
    await save(view);
    expect(jsonApiMocks.create.mock.calls[0]![2].config).toEqual(defaultConfig);
    expect(jsonApiMocks.create.mock.calls[0]![2]).not.toHaveProperty('secrets');
    expect(window.alert).not.toHaveBeenCalled();
  });

  it('round-trips saved source, schemas, HTTP permissions and unknown config fields without normalization', async () => {
    const config = {
      source: '\n-- Preserve whitespace and Unicode: счётчик\nreturn { counter = function(args)\n  return args\nend }\n\n',
      manifest: {
        functions: [{
          name: 'counter',
          description: 'Read and increment',
          input_schema: {
            type: 'object',
            properties: { amount: { type: 'integer', default: 2 }, tags: { type: 'array', items: { type: 'string' } } },
            required: ['amount'],
            additionalProperties: false,
          },
        }],
        permissions: {
          http: [{ methods: ['GET', 'POST'], url: 'https://api.example.com/v1/*', secrets: ['API_TOKEN'] }],
        },
        extension: { preserve: true },
      },
      extension: { preserve: ['future', 'config'] },
    };
    document = toolDocument({ config });
    const view = await mountEditor();
    expect(source(view).element.value).toBe(config.source);
    expect(JSON.parse(manifest(view).element.value)).toEqual(config.manifest);
    expect(view.getComponent(CrudHeader).props('dirty')).toBe(false);
    await view.get('input.full').setValue('Renamed Lua tool');
    await save(view);
    expect(jsonApiMocks.update.mock.calls[0]![3].config).toEqual(config);
    expect(jsonApiMocks.update.mock.calls[0]![3]).not.toHaveProperty('type');
    expect(source(view).element.value).toBe(config.source);
    expect(view.getComponent(CrudHeader).props('dirty')).toBe(false);
  });

  it('preserves invalid JSON through source edits and tab changes and blocks saving from another tab', async () => {
    const view = await mountEditor();
    const invalid = '{\n  "functions": [\n';
    await manifest(view).setValue(invalid);
    expect(view.text()).toContain('Invalid manifest JSON. Enter a valid JSON object.');
    expect(manifest(view).attributes('aria-invalid')).toBe('true');
    expect(view.getComponent(CrudHeader).props('dirty')).toBe(true);
    await source(view).setValue(`${defaultConfig.source}-- Local draft\n`);
    expect(manifest(view).element.value).toBe(invalid);
    await tab(view, 'Functions').trigger('click');
    await save(view);
    expect(tab(view, 'General').classes()).toContain('active');
    expect(manifest(view).element.value).toBe(invalid);
    expect(source(view).element.value).toContain('-- Local draft');
    expect(jsonApiMocks.update).not.toHaveBeenCalled();
    expect(clientMocks.post).not.toHaveBeenCalled();
  });

  it.each(['[]', 'null', 'true', '42', '"manifest"'])('rejects non-object manifest JSON: %s', async (text) => {
    const view = await mountEditor();
    await manifest(view).setValue(text);
    expect(view.text()).toContain('Manifest must be a JSON object.');
    await save(view);
    expect(jsonApiMocks.update).not.toHaveBeenCalled();
    expect(manifest(view).element.value).toBe(text);
    expect(view.getComponent(CrudHeader).props('dirty')).toBe(true);
  });

  it('accepts corrected JSON, updates the function preview and saves source and manifest together', async () => {
    const view = await mountEditor();
    const metadataDefaultsBeforeEdit = structuredClone(defaultConfig);
    const nextSource = '-- Updated source\nreturn { fetch = function(args) return args end }\n';
    const nextManifest = {
      functions: [{ name: 'fetch', description: 'Fetch API data', input_schema: { type: 'object', properties: {} } }],
      permissions: { http: [{ methods: ['GET'], url: 'https://api.example.com/v1/*', secrets: ['API_TOKEN'] }] },
    };
    await manifest(view).setValue('');
    expect(view.text()).toContain('Invalid manifest JSON.');
    await source(view).setValue(nextSource);
    await manifest(view).setValue(JSON.stringify(nextManifest));
    expect(manifest(view).attributes('aria-invalid')).toBe('false');
    await tab(view, 'Functions').trigger('click');
    expect(view.text()).toContain('Fetch API data');
    expect(view.text()).toContain('discovery is not used');
    expect(view.find('.tool-discover-button').exists()).toBe(false);
    expect(view.find('input[type="checkbox"]').exists()).toBe(false);
    expect(view.find('.tool-discovery-warning').exists()).toBe(false);
    await save(view);
    expect(jsonApiMocks.update.mock.calls[0]![3].config).toEqual({ source: nextSource, manifest: nextManifest });
    expect(view.getComponent(CrudHeader).props('dirty')).toBe(false);
    expect(clientMocks.post).not.toHaveBeenCalled();
    expect(luaMetadata.default_config).toEqual(metadataDefaultsBeforeEdit);
  });

  it('keeps an invalid-only draft dirty and does not replace it with metadata or remote document updates', async () => {
    const view = await mountEditor();
    const invalid = '{ "functions":';
    await manifest(view).setValue(invalid);
    serverStateQueryClient.setQueryData(serverStateKeys.reference('tool-types', 'driver-metadata'), [{
      ...luaMetadata,
      default_config: { ...defaultConfig, source: '-- Changed server example' },
    }]);
    serverStateQueryClient.setQueryData(serverStateKeys.detail('tool-instances', 27, 'editor-document'),
      toolDocument({ name: 'Renamed remotely', config: { ...defaultConfig, source: '-- Remote edit' } })
    );
    await flushPromises();
    expect(manifest(view).element.value).toBe(invalid);
    expect(source(view).element.value).toBe(defaultConfig.source);
    expect(view.getComponent(CrudHeader).props('dirty')).toBe(true);
    expect(view.findComponent(RemoteUpdateNotice).exists()).toBe(true);
  });

  it('resets both editors and clears invalid-only draft state on cancel', async () => {
    const view = await mountEditor();
    await manifest(view).setValue('{');
    await source(view).setValue('-- Unsaved source');
    view.getComponent(CrudHeader).vm.$emit('cancel');
    await flushPromises();
    expect(source(view).element.value).toBe(defaultConfig.source);
    expect(JSON.parse(manifest(view).element.value)).toEqual(defaultConfig.manifest);
    expect(manifest(view).attributes('aria-invalid')).toBe('false');
    expect(view.getComponent(CrudHeader).props('dirty')).toBe(false);
  });

  it('validates required source using metadata and keeps the manifest draft intact', async () => {
    const view = await mountEditor();
    const manifestDraft = JSON.stringify(defaultConfig.manifest);
    await manifest(view).setValue(manifestDraft);
    await source(view).setValue('   ');
    await save(view);
    expect(view.text()).toContain('Lua source is required.');
    expect(source(view).attributes('aria-invalid')).toBe('true');
    expect(manifest(view).element.value).toBe(manifestDraft);
    expect(jsonApiMocks.update).not.toHaveBeenCalled();
    await source(view).setValue(defaultConfig.source);
    expect(source(view).attributes('aria-invalid')).toBe('false');
  });

  it.each(['config', 'config/source', 'config/manifest/functions/0/input_schema'])(
    'shows server validation errors for %s without losing either draft', async (field) => {
      const view = await mountEditor();
      const sourceDraft = `${defaultConfig.source}-- Keep this source\n`;
      const manifestDraft = JSON.stringify(defaultConfig.manifest);
      await source(view).setValue(sourceDraft);
      await manifest(view).setValue(manifestDraft);
      jsonApiMocks.update.mockRejectedValueOnce(new HttpError({
        status: 422,
        statusText: 'Unprocessable Entity',
        bodyText: '',
        bodyJson: { errors: [{ detail: 'Invalid Lua configuration.', source: { pointer: `/data/attributes/${field}` } }] },
      }));
      await tab(view, 'Functions').trigger('click');
      await save(view);
      expect(tab(view, 'General').classes()).toContain('active');
      expect(view.text()).toContain('Invalid Lua configuration.');
      expect(source(view).element.value).toBe(sourceDraft);
      expect(manifest(view).element.value).toBe(manifestDraft);
      expect(view.getComponent(CrudHeader).props('dirty')).toBe(true);
      expect(window.alert).not.toHaveBeenCalled();
      await source(view).setValue(defaultConfig.source);
      await manifest(view).setValue(JSON.stringify(defaultConfig.manifest, null, 2));
      expect(view.text()).not.toContain('Invalid Lua configuration.');
    }
  );

  it('keeps shared Lua tools read-only while allowing inspection of functions and attached secrets', async () => {
    document = toolDocument({ can_edit: false, shared_incoming: true });
    const view = await mountEditor();
    expect(view.text()).toContain('This tool is read-only.');
    expect(source(view).attributes('readonly')).toBeDefined();
    expect(manifest(view).attributes('readonly')).toBeDefined();
    expect(source(view).element.closest('fieldset[disabled]')).not.toBeNull();
    expect(manifest(view).element.closest('fieldset[disabled]')).not.toBeNull();
    expect(view.getComponent(LuaToolSettings).props('readonly')).toBe(true);
    await source(view).setValue('-- Attempted edit');
    await manifest(view).setValue('{');
    expect(view.getComponent(LuaToolSettings).emitted('update:source')).toBeUndefined();
    expect(view.getComponent(LuaToolSettings).emitted('update:manifestText')).toBeUndefined();
    expect(view.getComponent(CrudHeader).props('dirty')).toBe(false);
    await save(view);
    expect(jsonApiMocks.update).not.toHaveBeenCalled();
    expect(tab(view, 'Secrets').element.closest('fieldset[disabled]')).toBeNull();
    await tab(view, 'Secrets').trigger('click');
    expect(tab(view, 'Secrets').text()).toContain('(1)');
    expect(view.getComponent(ManagedSecretsSection).props('readonly')).toBe(true);
    expect(view.getComponent(ManagedSecretsSection).props('secrets')[0].env_name).toBe('API_TOKEN');
    await tab(view, 'Functions').trigger('click');
    expect(view.text()).toContain('Read the counter');
    expect(view.find('.tool-discover-button').exists()).toBe(false);
    expect(clientMocks.post).not.toHaveBeenCalled();
    expect(clientMocks.patch).not.toHaveBeenCalled();
  });

  it('shows the Lua badge and supports English and Russian labels, hints, metadata and errors', async () => {
    expect(toolTypeLabel({ type: 'lua', type_title: null })).toBe('Lua');
    expect(toolTypeLabel({ type: 'lua', type_title: 'Server title' })).toBe('Server title');
    expect(toolTypeIconName('lua')).toBe('tool-terminal');
    setPreferredLocale('ru');
    const view = await mountEditor();
    expect(view.findAllComponents(ToolTypeBadge).some((badge) => badge.text() === 'Lua')).toBe(true);
    expect(source(view).attributes('aria-label')).toBe('Исходный код Lua');
    expect(manifest(view).attributes('aria-label')).toBe('Манифест JSON');
    expect(view.text()).toContain(ruMessages[luaMetadata.description]);
    expect(view.text()).toContain('Не помещайте значения секретов');
    await manifest(view).setValue('{');
    expect(view.text()).toContain('Невалидный JSON манифеста.');
    setPreferredLocale('en');
    await flushPromises();
    expect(source(view).attributes('aria-label')).toBe('Lua source');
    expect(view.text()).toContain('Invalid manifest JSON.');

    for (const key of [
      'Lua', 'Lua source', 'Manifest JSON', luaMetadata.description,
      'Lua code runs with per-chat-family state. Define the functions declared in the manifest.',
      'Define functions with name, description and input_schema, and explicitly allow HTTP methods, URL patterns and secret names in permissions.http.',
      'Attach secrets on the Secrets tab and reference their environment variable names in permissions.http[].secrets. Never put secret values in source code or the manifest.',
      'Manifest must be a JSON object.',
      'Invalid manifest JSON. Enter a valid JSON object.',
      'Lua functions are defined in the manifest on the General tab; discovery is not used.',
      'No functions declared in the manifest.',
      'Defined in the manifest',
      '{field} is required.',
    ]) {
      expect(messages.ru[key]).toBeTruthy();
      expect(translate(key)).toBe(key);
    }
  });
});
