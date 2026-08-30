import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { VueQueryPlugin } from '@tanstack/vue-query';
import { defineComponent, h, ref } from 'vue';

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

import { useManagedSecretsState } from '@/features/catalogs/model/useManagedSecretsState';
import { serverStateQueryClient } from '@/features/serverState/queryClient';

const storedSecret = {
  id: 7,
  external_id: '11111111-1111-4111-8111-111111111111',
  name: 'GitLab token',
  description: 'GitLab API access',
  env_name: 'GITLAB_TOKEN',
};

let wrapper: VueWrapper | null = null;

describe('useManagedSecretsState', () => {
  beforeEach(() => {
    serverStateQueryClient.clear();
    secretApi.create.mockReset();
    secretApi.delete.mockReset();
    secretApi.list.mockReset();
    secretApi.update.mockReset();
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    serverStateQueryClient.clear();
  });

  it('loads secrets eagerly and keeps edits in a resettable client draft', async () => {
    secretApi.list.mockResolvedValue({ secrets: [storedSecret] });
    const parentId = ref<number | null>(42);
    let state!: ReturnType<typeof useManagedSecretsState>;
    const Harness = defineComponent({
      setup() {
        state = useManagedSecretsState({ parent: 'knowledge-blocks', parentId });
        return () => h('div');
      },
    });

    wrapper = mount(Harness, {
      global: {
        plugins: [[VueQueryPlugin, { queryClient: serverStateQueryClient }]],
      },
    });
    await flushPromises();

    expect(secretApi.list).toHaveBeenCalledWith('knowledge-blocks', 42, { signal: expect.any(AbortSignal) });
    expect(state.secrets.value).toEqual([storedSecret]);

    const secondSecret = { ...storedSecret, id: 8, env_name: 'SECOND_TOKEN' };
    state.replaceSecrets([storedSecret, secondSecret]);
    await flushPromises();

    expect(state.secrets.value).toEqual([storedSecret, secondSecret]);
    expect(state.dirty.value).toBe(true);
    expect(secretApi.create).not.toHaveBeenCalled();

    state.reset();
    expect(state.secrets.value).toEqual([storedSecret]);
    expect(state.dirty.value).toBe(false);
  });

  it('persists deletes, edits, and additions only when the editor syncs on save', async () => {
    const removedSecret = { ...storedSecret, id: 8, env_name: 'OLD_TOKEN' };
    const updatedSecret = { ...storedSecret, name: 'Updated token' };
    const createdSecret = { ...storedSecret, id: 9, name: 'Deploy token', env_name: 'DEPLOY_TOKEN' };
    secretApi.list.mockResolvedValueOnce({ secrets: [storedSecret, removedSecret] });
    secretApi.delete.mockResolvedValue({ secrets: [storedSecret] });
    secretApi.update.mockResolvedValue({ secrets: [updatedSecret] });
    secretApi.create.mockResolvedValue({ secrets: [updatedSecret, createdSecret] });
    const parentId = ref<number | null>(42);
    let state!: ReturnType<typeof useManagedSecretsState>;
    const Harness = defineComponent({
      setup() {
        state = useManagedSecretsState({ parent: 'tool-instances', parentId });
        return () => h('div');
      },
    });

    wrapper = mount(Harness, {
      global: {
        plugins: [[VueQueryPlugin, { queryClient: serverStateQueryClient }]],
      },
    });
    await flushPromises();

    state.replaceSecrets([
      { ...storedSecret, name: 'Updated token', value: 'replacement' },
      {
        id: -1,
        external_id: 'pending-1',
        name: 'Deploy token',
        description: '',
        env_name: 'DEPLOY_TOKEN',
        value: 'new-secret',
      },
    ]);
    await flushPromises();

    expect(secretApi.delete).not.toHaveBeenCalled();
    expect(secretApi.update).not.toHaveBeenCalled();
    expect(secretApi.create).not.toHaveBeenCalled();

    await state.sync(42);

    expect(secretApi.delete).toHaveBeenCalledWith('tool-instances', 42, 8);
    expect(secretApi.update).toHaveBeenCalledWith('tool-instances', 42, 7, {
      name: 'Updated token',
      description: 'GitLab API access',
      env_name: 'GITLAB_TOKEN',
      value: 'replacement',
    });
    expect(secretApi.create).toHaveBeenCalledWith('tool-instances', 42, {
      name: 'Deploy token',
      description: '',
      env_name: 'DEPLOY_TOKEN',
      value: 'new-secret',
    });
    expect(state.secrets.value).toEqual([updatedSecret, createdSecret]);
    expect(state.dirty.value).toBe(false);
  });

  it('keeps a new-parent draft while the parent receives its saved id', async () => {
    secretApi.list.mockResolvedValue({ secrets: [] });
    const createdSecret = { ...storedSecret, id: 12 };
    secretApi.create.mockResolvedValue({ secrets: [createdSecret] });
    const parentId = ref<number | null>(null);
    let state!: ReturnType<typeof useManagedSecretsState>;
    const Harness = defineComponent({
      setup() {
        state = useManagedSecretsState({ parent: 'knowledge-blocks', parentId });
        return () => h('div');
      },
    });

    wrapper = mount(Harness, {
      global: {
        plugins: [[VueQueryPlugin, { queryClient: serverStateQueryClient }]],
      },
    });
    state.replaceSecrets([
      {
        ...storedSecret,
        id: -1,
        external_id: 'pending-1',
        value: 'new-secret',
      },
    ]);
    parentId.value = 55;
    await flushPromises();

    expect(state.secrets.value[0]?.id).toBe(-1);
    await state.sync(55);
    expect(secretApi.create).toHaveBeenCalledWith('knowledge-blocks', 55, {
      name: 'GitLab token',
      description: 'GitLab API access',
      env_name: 'GITLAB_TOKEN',
      value: 'new-secret',
    });
    expect(state.secrets.value).toEqual([createdSecret]);
  });
});
