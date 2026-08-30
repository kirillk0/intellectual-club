import { flushPromises, mount } from '@vue/test-utils';
import { afterEach, describe, expect, it, vi } from 'vitest';

const secretApi = vi.hoisted(() => ({
  create: vi.fn(),
  delete: vi.fn(),
  list: vi.fn(),
  update: vi.fn(),
}));

vi.mock('@/api/managedSecrets', async () => {
  const actual = await vi.importActual<typeof import('@/api/managedSecrets')>('@/api/managedSecrets');
  return {
    ...actual,
    createManagedSecret: secretApi.create,
    deleteManagedSecret: secretApi.delete,
    listManagedSecrets: secretApi.list,
    updateManagedSecret: secretApi.update,
  };
});

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
    document.body.innerHTML = '';
  });

  it('renders a resource-owned table and uses the same modal for create and edit', async () => {
    secretApi.list.mockResolvedValue({ secrets: [storedSecret] });

    const wrapper = mount(ManagedSecretsSection, {
      props: { parent: 'knowledge-blocks', parentId: 42 },
      attachTo: document.body,
    });
    await flushPromises();

    expect(secretApi.list).toHaveBeenCalledWith('knowledge-blocks', 42);
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
});
