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
import LlmConfigurationTagsPickerModal from '@/components/LlmConfigurationTagsPickerModal.vue';
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
  web_search_enabled: boolean;
  enabled: boolean;
  timeout_seconds: number;
  context_length: number | null;
  cold_input_price_per_million_tokens: number | null;
  cached_input_price_per_million_tokens: number | null;
  output_price_per_million_tokens: number | null;
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
  web_search_enabled: false,
  enabled: true,
  timeout_seconds: 300,
  context_length: null,
  cold_input_price_per_million_tokens: null,
  cached_input_price_per_million_tokens: null,
  output_price_per_million_tokens: null,
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
    included: [
      {
        id: '4',
        type: 'llm-providers',
        attributes: { name: 'OpenRouter provider', type: 'openrouter_chat_completion' },
      },
    ],
  };
}

let wrapper: VueWrapper | null = null;

async function mountView(path: string) {
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
    jsonApiMocks.list.mockReset().mockImplementation(async (path: string) => {
      if (path === '/api/ash/llm-providers') {
        return {
          data: [
            {
              id: '4',
              type: 'llm-providers',
              attributes: { name: 'OpenRouter provider', type: 'openrouter_chat_completion' },
            },
            {
              id: '5',
              type: 'llm-providers',
              attributes: { name: 'NVIDIA provider', type: 'nvidia_build_chat_completion' },
            },
            {
              id: '6',
              type: 'llm-providers',
              attributes: { name: 'Responses provider', type: 'responses' },
            },
            {
              id: '7',
              type: 'llm-providers',
              attributes: { name: 'Responses WSS provider', type: 'responses_wss' },
            },
            {
              id: '8',
              type: 'llm-providers',
              attributes: { name: 'Google provider', type: 'google_interactions' },
            },
            {
              id: '9',
              type: 'llm-providers',
              attributes: { name: 'Anthropic provider', type: 'anthropic_messages' },
            },
            {
              id: '10',
              type: 'llm-providers',
              attributes: { name: 'Demo provider', type: 'demo' },
            },
          ],
        };
      }
      return { data: [] };
    });
    jsonApiMocks.update.mockReset();
    clientMocks.get.mockReset().mockImplementation(async (path: string) => {
      if (path === '/api/bff/me/groups') return { groups: [] };
      if (path === '/api/bff/llm-provider-types') {
        return {
          types: [
            { type: 'responses', supports_hosted_web_search: true },
            { type: 'responses_wss', supports_hosted_web_search: true },
            { type: 'openrouter_chat_completion', supports_hosted_web_search: true },
            { type: 'google_interactions', supports_hosted_web_search: true },
            { type: 'anthropic_messages', supports_hosted_web_search: true },
            { type: 'nvidia_build_chat_completion', supports_hosted_web_search: false },
            { type: 'demo', supports_hosted_web_search: false },
          ],
        };
      }
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
    const timeout = view
      .findAll('label')
      .find((label) => label.text().includes('Timeout (seconds)'))
      ?.get<HTMLInputElement>('input');

    expect(temperatureMode.element.value).toBe('default');
    expect(timeout?.element.value).toBe('120');
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

  it('reapplies the filtered tag after saving and creating another configuration', async () => {
    jsonApiMocks.create.mockResolvedValue(configurationDocument());
    const view = await mountView(
      '/catalogs/llm-configurations/new?recordsetKey=filtered-configs&defaultTagId=9'
    );
    const router = view.vm.$router;

    expect(view.getComponent(LlmConfigurationTagsPickerModal).props('selectedTagIds')).toEqual([9]);

    header(view).vm.$emit('save');
    await vi.waitFor(() => expect(jsonApiMocks.create).toHaveBeenCalledTimes(1));
    expect(jsonApiMocks.create.mock.calls[0]?.[2]).toMatchObject({
      tag_bindings: [{ llm_configuration_tag_id: 9 }],
    });
    await vi.waitFor(() => expect(router.currentRoute.value.path).toBe('/catalogs/llm-configurations/27'));
    expect(router.currentRoute.value.query).toMatchObject({
      recordsetKey: 'filtered-configs',
      defaultTagId: '9',
    });

    header(view).vm.$emit('create');
    await vi.waitFor(() => expect(router.currentRoute.value.path).toBe('/catalogs/llm-configurations/new'));
    expect(router.currentRoute.value.query).toMatchObject({
      recordsetKey: 'filtered-configs',
      defaultTagId: '9',
    });
    expect(view.getComponent(LlmConfigurationTagsPickerModal).props('selectedTagIds')).toEqual([9]);
  });

  it('requires a complete manual pricing set and saves zero as a configured price', async () => {
    jsonApiMocks.create.mockResolvedValue(
      configurationDocument({
        cold_input_price_per_million_tokens: 1.25,
        cached_input_price_per_million_tokens: 0,
        output_price_per_million_tokens: 8.5,
      })
    );

    const view = await mountView('/catalogs/llm-configurations/new');
    const coldInput = view.get<HTMLInputElement>('#llm-configuration-cold-input-price');
    const cachedInput = view.get<HTMLInputElement>('#llm-configuration-cached-input-price');
    const output = view.get<HTMLInputElement>('#llm-configuration-output-price');

    expect(coldInput.element.value).toBe('');
    expect(cachedInput.element.value).toBe('');
    expect(output.element.value).toBe('');
    expect(coldInput.attributes()).toMatchObject({ min: '0', step: 'any' });

    await coldInput.setValue('1.25');
    header(view).vm.$emit('save');
    await nextTick();

    expect(view.text()).toContain('Fill all three prices or leave all three empty.');
    expect(jsonApiMocks.create).not.toHaveBeenCalled();

    await cachedInput.setValue('0');
    await output.setValue('8.5');
    header(view).vm.$emit('save');

    await vi.waitFor(() => expect(jsonApiMocks.create).toHaveBeenCalledTimes(1));
    expect(jsonApiMocks.create.mock.calls[0]?.[2]).toMatchObject({
      cold_input_price_per_million_tokens: 1.25,
      cached_input_price_per_million_tokens: 0,
      output_price_per_million_tokens: 8.5,
    });
  });

  it('rejects negative manual prices before saving', async () => {
    const view = await mountView('/catalogs/llm-configurations/new');

    await view.get('#llm-configuration-cold-input-price').setValue('-0.01');
    await view.get('#llm-configuration-cached-input-price').setValue('0');
    await view.get('#llm-configuration-output-price').setValue('1');
    header(view).vm.$emit('save');
    await nextTick();

    expect(view.text()).toContain('Manual prices must be non-negative.');
    expect(jsonApiMocks.create).not.toHaveBeenCalled();
  });

  it('loads persisted values and sends explicit values or null in the update payload', async () => {
    jsonApiMocks.get.mockResolvedValue(
      configurationDocument({
        temperature: 0.7,
        reasoning_effort: 'high',
        web_search_enabled: true,
        cold_input_price_per_million_tokens: 1.25,
        cached_input_price_per_million_tokens: 0.25,
        output_price_per_million_tokens: 8.5,
      })
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
      web_search_enabled: true,
      cold_input_price_per_million_tokens: 1.25,
      cached_input_price_per_million_tokens: 0.25,
      output_price_per_million_tokens: 8.5,
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
    expect(view.get('#llm-configuration-web-search-enabled').attributes('disabled')).toBeDefined();
    expect(view.get('#llm-configuration-cold-input-price').attributes('disabled')).toBeDefined();
    expect(view.get('#llm-configuration-cached-input-price').attributes('disabled')).toBeDefined();
    expect(view.get('#llm-configuration-output-price').attributes('disabled')).toBeDefined();
  });

  it('enables hosted web search by provider type and preserves the value across unsupported types', async () => {
    const view = await mountView('/catalogs/llm-configurations/new');
    const provider = view.get<HTMLSelectElement>('select.full');
    const webSearch = view.get<HTMLInputElement>('#llm-configuration-web-search-enabled');

    expect(webSearch.attributes('disabled')).toBeDefined();

    for (const providerId of ['4', '6', '7', '8', '9']) {
      await provider.setValue(providerId);
      await flushPromises();
      expect(webSearch.attributes('disabled')).toBeUndefined();
    }

    await webSearch.setValue(true);
    expect(webSearch.element.checked).toBe(true);
    expect(header(view).props('dirty')).toBe(true);

    for (const providerId of ['5', '10']) {
      await provider.setValue(providerId);
      await flushPromises();
      expect(webSearch.attributes('disabled')).toBeDefined();
      expect(webSearch.element.checked).toBe(true);
    }

    await provider.setValue('4');
    await flushPromises();
    expect(webSearch.attributes('disabled')).toBeUndefined();
    expect(webSearch.element.checked).toBe(true);
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
      'Cached input (USD / 1M tokens)',
      'Cold input (USD / 1M tokens)',
      'Default',
      'Default leaves the corresponding request parameter unset, so values from Advanced JSON remain unchanged.',
      'High',
      'Hosted web search',
      'Hosted web search is not available for this provider type.',
      'Low',
      'Manual prices must be non-negative.',
      'Manual pricing',
      'Max',
      'Medium',
      'Minimal',
      'None',
      'Output (USD / 1M tokens)',
      'Reasoning effort',
      'Temperature',
      'XHigh',
      'Fill all three prices or leave all three empty.',
      'USD per 1M tokens. Used only when the provider does not report cost.',
      "Uses the provider's hosted web search tool.",
    ];

    expect(keys.every((key) => Boolean(ruMessages[key]))).toBe(true);
  });
});
