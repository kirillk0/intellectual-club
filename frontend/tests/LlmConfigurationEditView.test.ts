import { flushPromises, shallowMount, type VueWrapper } from '@vue/test-utils';
import { VueQueryPlugin } from '@tanstack/vue-query';
import { nextTick } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

const jsonApiMocks = vi.hoisted(() => ({
  create: vi.fn(),
  get: vi.fn(),
  list: vi.fn(),
  update: vi.fn(),
}));

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
import { useNavigationStack } from '@/features/stack/navigationStack';
import { serverStateQueryClient } from '@/features/serverState/queryClient';
import { ruMessages } from '@/i18n/messages';
import LlmConfigurationEditView from '@/views/catalogs/LlmConfigurationEditView.vue';

type ConfigurationAttributes = {
  provider_id: number;
  model_name: string;
  note: string | null;
  parameters: Record<string, unknown>;
  temperature: number | null;
  reasoning_effort: string | null;
  enabled: boolean;
  timeout_seconds: number;
  context_length: number | null;
  supports_cache_control: boolean;
  supports_image_input: boolean;
  supports_steering: boolean;
  fix_role_alteration: boolean;
  can_edit: boolean;
  shared_incoming: boolean;
  shared_outgoing: boolean;
};

const defaultAttributes: ConfigurationAttributes = {
  provider_id: 4,
  model_name: 'test-model',
  note: null,
  parameters: { native_setting: 'kept' },
  temperature: null,
  reasoning_effort: null,
  enabled: true,
  timeout_seconds: 300,
  context_length: null,
  supports_cache_control: false,
  supports_image_input: false,
  supports_steering: true,
  fix_role_alteration: false,
  can_edit: true,
  shared_incoming: false,
  shared_outgoing: false,
};

function configurationDocument(overrides: Partial<ConfigurationAttributes> = {}) {
  return {
    data: {
      id: '27',
      type: 'llm-configurations',
      attributes: { ...defaultAttributes, ...overrides },
      relationships: {
        provider: { data: { id: '4', type: 'llm-providers' } },
        knowledge_block_bindings: { data: [] },
        tag_bindings: { data: [] },
      },
    },
    included: [{ id: '4', type: 'llm-providers', attributes: { name: 'Test provider' } }],
  };
}

let wrapper: VueWrapper | null = null;

async function mountView(path: '/catalogs/llm-configurations/new' | '/catalogs/llm-configurations/27') {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/catalogs/llm-configurations', component: { template: '<div />' } },
      { path: '/catalogs/llm-configurations/:id', component: { template: '<div />' } },
    ],
  });
  await router.push(path);
  await router.isReady();

  wrapper = shallowMount(LlmConfigurationEditView, {
    global: {
      plugins: [router, [VueQueryPlugin, { queryClient: serverStateQueryClient }]],
    },
  });

  await flushPromises();
  return wrapper;
}

function header(view: VueWrapper) {
  return view.getComponent(CrudHeader);
}

describe('LlmConfigurationEditView standard parameters', () => {
  beforeEach(() => {
    serverStateQueryClient.clear();
    useNavigationStack().reset();
    jsonApiMocks.create.mockReset();
    jsonApiMocks.get.mockReset();
    jsonApiMocks.list.mockReset().mockResolvedValue({ data: [] });
    jsonApiMocks.update.mockReset();
    clientMocks.get.mockReset().mockImplementation(async (path: string) => {
      if (path === '/api/bff/me/groups') return { groups: [] };
      if (path.endsWith('/shares')) return { group_ids: [] };
      if (path.endsWith('/models')) return { models: [] };
      throw new Error(`Unexpected GET request: ${path}`);
    });
    clientMocks.put.mockReset();
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    serverStateQueryClient.clear();
    useNavigationStack().reset();
  });

  it('starts with Default values and resets a dirty draft', async () => {
    const view = await mountView('/catalogs/llm-configurations/new');
    const temperatureMode = view.get<HTMLSelectElement>('#llm-configuration-temperature-mode');
    const reasoningEffort = view.get<HTMLSelectElement>('#llm-configuration-reasoning-effort');

    expect(temperatureMode.element.value).toBe('default');
    expect(view.find('input[aria-label="Temperature"]').exists()).toBe(false);
    expect(Array.from(reasoningEffort.element.options).map((option) => option.value)).toEqual([
      '',
      'none',
      'minimal',
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
    ]);

    await temperatureMode.setValue('custom');
    const temperature = view.get<HTMLInputElement>('input[aria-label="Temperature"]');
    expect(temperature.element.value).toBe('1');
    expect(temperature.attributes()).toMatchObject({ min: '0', max: '2', step: 'any' });

    await temperature.setValue('0.65');
    await reasoningEffort.setValue('minimal');
    await nextTick();
    expect(header(view).props('dirty')).toBe(true);

    header(view).vm.$emit('cancel');
    await nextTick();

    expect(temperatureMode.element.value).toBe('default');
    expect(reasoningEffort.element.value).toBe('');
    expect(view.find('input[aria-label="Temperature"]').exists()).toBe(false);
    expect(header(view).props('dirty')).toBe(false);
  });

  it('loads persisted values and sends explicit values or null in the update payload', async () => {
    jsonApiMocks.get.mockResolvedValue(
      configurationDocument({ temperature: 0.7, reasoning_effort: 'high' })
    );
    jsonApiMocks.update.mockImplementation(
      async (_basePath: string, _type: string, _id: number, attributes: ConfigurationAttributes) =>
        configurationDocument(attributes)
    );

    const view = await mountView('/catalogs/llm-configurations/27');
    await vi.waitFor(() =>
      expect(view.get<HTMLSelectElement>('#llm-configuration-temperature-mode').element.value).toBe('custom')
    );

    await view.get<HTMLInputElement>('input[aria-label="Temperature"]').setValue('0');
    await view.get('#llm-configuration-reasoning-effort').setValue('max');
    header(view).vm.$emit('save');
    await vi.waitFor(() => expect(jsonApiMocks.update).toHaveBeenCalledTimes(1));

    expect(jsonApiMocks.update.mock.calls[0]?.[3]).toMatchObject({
      parameters: { native_setting: 'kept' },
      temperature: 0,
      reasoning_effort: 'max',
    });

    await view.get('#llm-configuration-temperature-mode').setValue('default');
    await view.get('#llm-configuration-reasoning-effort').setValue('');
    header(view).vm.$emit('save');
    await vi.waitFor(() => expect(jsonApiMocks.update).toHaveBeenCalledTimes(2));

    expect(jsonApiMocks.update.mock.calls[1]?.[3]).toMatchObject({
      parameters: { native_setting: 'kept' },
      temperature: null,
      reasoning_effort: null,
    });
  });

  it('disables both controls for a shared read-only configuration', async () => {
    jsonApiMocks.get.mockResolvedValue(
      configurationDocument({ can_edit: false, temperature: 1.2, reasoning_effort: 'medium' })
    );

    const view = await mountView('/catalogs/llm-configurations/27');
    await vi.waitFor(() => expect(view.text()).toContain('This configuration is read-only.'));

    expect(view.get('#llm-configuration-temperature-mode').attributes('disabled')).toBeDefined();
    expect(view.get('input[aria-label="Temperature"]').attributes('disabled')).toBeDefined();
    expect(view.get('#llm-configuration-reasoning-effort').attributes('disabled')).toBeDefined();
  });

  it('shows and clears field-specific API errors', async () => {
    jsonApiMocks.get.mockResolvedValue(configurationDocument());
    jsonApiMocks.update.mockRejectedValue(
      new HttpError({
        status: 422,
        statusText: 'Unprocessable Content',
        bodyText: '',
        bodyJson: {
          errors: [
            {
              detail: 'Temperature must be between 0 and 2.',
              source: { pointer: '/data/attributes/temperature' },
            },
            {
              detail: 'Reasoning effort is invalid.',
              source: { pointer: '/data/attributes/reasoning_effort' },
            },
          ],
        },
      })
    );

    const view = await mountView('/catalogs/llm-configurations/27');
    await vi.waitFor(() => expect(view.find('#llm-configuration-temperature-mode').exists()).toBe(true));
    await view.get('#llm-configuration-temperature-mode').setValue('custom');
    await view.get('#llm-configuration-reasoning-effort').setValue('low');
    header(view).vm.$emit('save');
    await vi.waitFor(() => expect(view.text()).toContain('Temperature must be between 0 and 2.'));

    expect(view.text()).toContain('Reasoning effort is invalid.');
    expect(view.findAll('.field-error')).toHaveLength(2);

    await view.get('input[aria-label="Temperature"]').setValue('1.1');
    await view.get('#llm-configuration-reasoning-effort').setValue('medium');
    expect(view.text()).not.toContain('Temperature must be between 0 and 2.');
    expect(view.text()).not.toContain('Reasoning effort is invalid.');
  });

  it('has Russian translations for every new label and explanation', () => {
    const keys = [
      'Available reasoning effort levels depend on the selected model.',
      'Default',
      'Default leaves the corresponding request parameter unset, so values from Advanced JSON remain unchanged.',
      'High',
      'Low',
      'Max',
      'Medium',
      'Minimal',
      'None',
      'Reasoning effort',
      'Temperature',
      'XHigh',
    ];

    expect(keys.every((key) => Boolean(ruMessages[key]))).toBe(true);
  });
});
