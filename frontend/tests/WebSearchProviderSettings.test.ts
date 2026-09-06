import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';
import WebSearchProviderSettings from '@/features/tools/components/WebSearchProviderSettings.vue';

const providerSchemas = Object.fromEntries(['brave', 'tavily', 'tinyfish', 'exa', 'firecrawl'].map((id) => [id, { title: id, properties: { api_base_url: { default: `https://${id}.example` } } }]));
function setup(providers = ['brave']) {
  const wrapper = mount(WebSearchProviderSettings, { props: { modelValue: { providers, timeout_seconds: 17, provider_options: { brave: { api_base_url: 'https://proxy.example' } } }, providerSchemas } });
  async function apply() {
    const events = wrapper.emitted('update:modelValue');
    await wrapper.setProps({ modelValue: events![events!.length - 1]![0] as Record<string, unknown> });
  }
  return { wrapper, apply };
}

describe('WebSearchProviderSettings', () => {
  it('adds at most three unique providers and preserves settings while reordering', async () => {
    const { wrapper, apply } = setup();
    expect(wrapper.text()).toContain('built-in Web Reader');
    const add = () => wrapper.findAll('button').find((button) => button.text() === 'Add fallback provider')!;
    await add().trigger('click'); await apply();
    await add().trigger('click'); await apply();
    expect(wrapper.findAll('select')).toHaveLength(3);
    expect(add().attributes('disabled')).toBeDefined();
    await wrapper.get('button[aria-label="Move up 2"]').trigger('click'); await apply();
    expect(wrapper.props('modelValue').providers).toEqual(['tavily', 'brave', 'tinyfish']);
    expect(wrapper.props('modelValue').timeout_seconds).toBe(17);
    expect(wrapper.props('modelValue').provider_options).toEqual({ brave: { api_base_url: 'https://proxy.example' } });
    expect(wrapper.findAll('select')[0]!.find('option[value="brave"]').attributes('disabled')).toBeDefined();
  });

  it('retains inactive provider endpoints and prevents removal of the last provider', async () => {
    const { wrapper, apply } = setup();
    expect(wrapper.findAll('button').find((button) => button.text() === 'Remove provider')!.attributes('disabled')).toBeDefined();
    await wrapper.get('select').setValue('exa'); await apply();
    await wrapper.get('input[type="url"]').setValue('https://custom-exa.example'); await apply();
    expect(wrapper.props('modelValue').provider_options).toEqual({ brave: { api_base_url: 'https://proxy.example' }, exa: { api_base_url: 'https://custom-exa.example' } });
    await wrapper.get('input[type="url"]').setValue(''); await apply();
    expect(wrapper.props('modelValue').provider_options).toEqual({ brave: { api_base_url: 'https://proxy.example' }, exa: {} });
  });
});
