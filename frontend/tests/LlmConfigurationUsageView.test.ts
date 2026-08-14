import { flushPromises, mount } from '@vue/test-utils';
import { createMemoryHistory, createRouter } from 'vue-router';

const clientMocks = vi.hoisted(() => ({
  get: vi.fn(),
}));

vi.mock('@/api/client', async () => {
  const actual = await vi.importActual<typeof import('@/api/client')>('@/api/client');
  return {
    ...actual,
    api: {
      ...actual.api,
      get: clientMocks.get,
    },
  };
});

import { setPreferredLocale } from '@/i18n';
import LlmConfigurationUsageView from '@/views/catalogs/LlmConfigurationUsageView.vue';

describe('LlmConfigurationUsageView token breakdowns', () => {
  beforeEach(() => {
    setPreferredLocale('en');
    localStorage.clear();
    localStorage.setItem(
      'ic.llm_usage.visible_metrics.v1',
      JSON.stringify(['input_tokens_m', 'output_tokens_m'])
    );
    localStorage.setItem(
      'ic.llm_usage.period.v1',
      JSON.stringify({ period: 'custom', from: '2026-08-01', to: '2026-08-14' })
    );
    clientMocks.get.mockReset();
    clientMocks.get.mockResolvedValue({
      from: '2026-08-01',
      to: '2026-08-14',
      users: [{ id: 7, username: 'agent' }],
      rows: [
        {
          key: 'configuration:27',
          configuration_id: 27,
          label: 'test-model',
          deleted: false,
          shared_incoming: false,
          shared_outgoing: false,
          cells: {
            '7': {
              message_count: 2,
              step_count: 3,
              input_tokens: 1_000_000,
              cached_input_tokens: 250_000,
              output_tokens: 3_400,
              reasoning_tokens: 1_600,
              cache_hit_percent: 25,
              cost: 1.5,
            },
          },
        },
      ],
    });
  });

  afterEach(() => {
    setPreferredLocale(null);
    localStorage.clear();
  });

  it('shows total input and output as grouped metrics instead of additive flat metrics', async () => {
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/catalogs/llm-configurations/usage', component: { template: '<div />' } }],
    });
    await router.push('/catalogs/llm-configurations/usage');
    await router.isReady();

    const wrapper = mount(LlmConfigurationUsageView, {
      global: {
        plugins: [router],
        stubs: {
          InitialRoutePlaceholder: true,
          StackToolbarTeleport: { template: '<div><slot /></div>' },
        },
      },
    });

    await flushPromises();

    const metrics = wrapper.findAll('.usage-cell__metric--tokens');
    expect(metrics).toHaveLength(2);
    expect(metrics[0]!.get('.usage-cell__metric-main').text()).toBe('Input tokens (total)1.000M');
    expect(metrics[0]!.findAll('.usage-cell__metric-part').map((part) => part.text())).toEqual([
      'Cold input0.750M',
      'Cached input0.250M',
    ]);
    expect(metrics[1]!.get('.usage-cell__metric-main').text()).toBe(
      'Output tokens (total, incl. reasoning)0.0034M'
    );
    expect(metrics[1]!.findAll('.usage-cell__metric-part').map((part) => part.text())).toEqual([
      'Non-reasoning0.0018M',
      'Reasoning0.0016M',
    ]);
    expect(wrapper.findAll('.usage-metric-toggle').map((button) => button.text())).not.toContain(
      'Cached input tok.'
    );

    wrapper.unmount();
  });
});
