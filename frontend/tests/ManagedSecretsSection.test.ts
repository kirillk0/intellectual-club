import { flushPromises, mount } from '@vue/test-utils';
import { afterEach, describe, expect, it } from 'vitest';

import ManagedSecretsSection from '@/features/catalogs/components/secrets/ManagedSecretsSection.vue';
import ManagedSecretModal from '@/features/catalogs/components/secrets/ManagedSecretModal.vue';

const storedSecret = {
  id: 7,
  external_id: '11111111-1111-4111-8111-111111111111',
  name: 'GitLab token',
  description: 'GitLab API access',
  env_name: 'GITLAB_TOKEN',
};

describe('ManagedSecretsSection', () => {
  afterEach(() => {
    vi.clearAllMocks();
    vi.unstubAllGlobals();
    document.body.innerHTML = '';
  });

  it('renders a resource-owned table and uses the same modal for create and edit', async () => {
    const wrapper = mount(ManagedSecretsSection, {
      props: {
        secrets: [storedSecret],
        loading: false,
        loadError: null,
      },
      attachTo: document.body,
    });
    await flushPromises();

    expect(wrapper.get('table').text()).toContain('GitLab token');
    expect(wrapper.get('table').text()).toContain('GITLAB_TOKEN');
    expect(wrapper.find('select').exists()).toBe(false);
    expect(wrapper.find('input[type="checkbox"]').exists()).toBe(false);
    expect(wrapper.findAll('button[aria-label="Edit secret"]')).toHaveLength(1);
    expect(wrapper.findAll('button[aria-label="Delete secret"]')).toHaveLength(1);
    expect(wrapper.find('.managed-secrets__actions template').exists()).toBe(false);

    await wrapper.get('button[aria-label="Create secret"]').trigger('click');
    let modal = wrapper.getComponent(ManagedSecretModal);
    expect(modal.props('open')).toBe(true);
    expect(modal.props('secret')).toBeNull();

    modal.vm.$emit('update:open', false);
    await wrapper.vm.$nextTick();
    await wrapper.get('button[aria-label="Edit secret"]').trigger('click');
    modal = wrapper.getComponent(ManagedSecretModal);
    expect(modal.props('open')).toBe(true);
    expect(modal.props('secret')).toEqual(storedSecret);
  });

  it('emits a client-only draft after creating a secret', async () => {
    const wrapper = mount(ManagedSecretsSection, {
      props: {
        secrets: [storedSecret],
        loading: false,
        loadError: null,
      },
      attachTo: document.body,
    });
    await flushPromises();

    await wrapper.get('button[aria-label="Create secret"]').trigger('click');
    wrapper.getComponent(ManagedSecretModal).vm.$emit('save', {
      name: 'Deploy token',
      description: '',
      env_name: 'DEPLOY_TOKEN',
      value: 'secret-value',
    });
    await flushPromises();

    expect(wrapper.emitted('update:secrets')).toEqual([
      [[
        storedSecret,
        {
          id: -1,
          external_id: 'pending-1',
          name: 'Deploy token',
          description: '',
          env_name: 'DEPLOY_TOKEN',
          value: 'secret-value',
        },
      ]],
    ]);
  });

  it('allows secrets to be drafted before the parent is saved', async () => {
    const wrapper = mount(ManagedSecretsSection, {
      props: {
        secrets: [],
        loading: false,
        loadError: null,
        dirty: false,
      },
      attachTo: document.body,
    });

    expect(wrapper.get('button[aria-label="Create secret"]').attributes('disabled')).toBeUndefined();
    expect(wrapper.text()).not.toContain('Save this item before creating secrets.');
  });

  it.each([true, false])('masks secret entry with CSS support=%s and preserves the exact value', async (supported) => {
    vi.stubGlobal('CSS', { supports: () => supported });
    const wrapper = mount(ManagedSecretModal, {
      props: { open: true, secret: null, saving: false, error: null },
      global: { stubs: { teleport: true } },
    });
    const inputs = wrapper.findAll('input');
    await inputs[0]!.setValue('API token');
    await inputs[1]!.setValue('API_TOKEN');
    const valueInput = wrapper.get('.managed-secret-modal__value');
    expect(valueInput.attributes('type')).toBe(supported ? 'text' : 'password');
    expect(valueInput.attributes('autocomplete')).toBe('off');
    expect(valueInput.attributes('spellcheck')).toBe('false');
    await valueInput.setValue('  exact-token  ');
    await wrapper.get('button.primary').trigger('click');
    expect(wrapper.emitted('save')).toEqual([[{
      name: 'API token', env_name: 'API_TOKEN', description: '', value: '  exact-token  ',
    }]]);
    wrapper.unmount();
  });
});
