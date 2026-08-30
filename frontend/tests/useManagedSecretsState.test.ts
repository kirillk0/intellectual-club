import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { VueQueryPlugin } from '@tanstack/vue-query';
import { defineComponent, h, ref } from 'vue';

const secretApi = vi.hoisted(() => ({
  list: vi.fn(),
}));

vi.mock('@/api/managedSecrets', async () => {
  const actual = await vi.importActual<typeof import('@/api/managedSecrets')>('@/api/managedSecrets');
  return {
    ...actual,
    listManagedSecrets: secretApi.list,
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
    secretApi.list.mockReset();
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    serverStateQueryClient.clear();
  });

  it('loads secrets eagerly and updates the shared canonical list', async () => {
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
  });
});
