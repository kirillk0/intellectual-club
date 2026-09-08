import { VueQueryPlugin } from '@tanstack/vue-query';
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { defineComponent, h } from 'vue';
import { createMemoryHistory, createRouter, RouterView } from 'vue-router';

const apiMocks = vi.hoisted(() => ({
  create: vi.fn(),
  get: vi.fn(),
  listGroups: vi.fn(),
}));

vi.mock('@/api/jsonApi', async () => ({
  ...await vi.importActual<typeof import('@/api/jsonApi')>('@/api/jsonApi'),
  jsonApiCreate: apiMocks.create,
  jsonApiGet: apiMocks.get,
}));

vi.mock('@/api/adminAshApi', async () => ({
  ...await vi.importActual<typeof import('@/api/adminAshApi')>('@/api/adminAshApi'),
  listAdminUserGroups: apiMocks.listGroups,
}));

vi.mock('@/features/auth/session', async () => {
  const { ref } = await import('vue');
  return {
    useSessionAuth: () => ({ currentUser: ref({ id: 1 }) }),
    fetchCurrentUser: vi.fn(),
  };
});

import CrudHeader from '@/components/CrudHeader.vue';
import { serverStateQueryClient } from '@/features/serverState/queryClient';
import { useNavigationStack } from '@/features/stack/navigationStack';
import UserEditView from '@/views/administration/UserEditView.vue';

const savedUser = {
  data: {
    id: '123',
    type: 'users',
    attributes: { username: 'new-user', is_admin: false },
    relationships: { groups: { data: [] } },
  },
};
const password = 'initial-password';
const warning = 'You have unsaved changes. Leave without saving?';
let wrapper: VueWrapper | null = null;

async function mountNewUser(stacked = false) {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/administration/users', component: { template: '<div />' } },
      { path: '/administration/users/:id', component: UserEditView },
    ],
  });

  if (stacked) {
    await router.push('/administration/users');
    const parentRoute = router.currentRoute.value;
    useNavigationStack().markPendingPush(0);
    await router.push('/administration/users/new');
    useNavigationStack().commitPendingPush(parentRoute);
  } else {
    await router.push('/administration/users/new');
  }
  await router.isReady();

  wrapper = mount(defineComponent({ render: () => h(RouterView) }), {
    global: {
      plugins: [router, [VueQueryPlugin, { queryClient: serverStateQueryClient }]],
      stubs: { CrudHeader: true, RemoteUpdateNotice: true },
    },
  });
  await flushPromises();
  const view = wrapper.getComponent(UserEditView);
  await view.get('input[autocomplete="username"]').setValue('new-user');
  for (const input of view.findAll('input[type="password"]')) {
    await input.setValue(password);
  }
  return { router, view, header: view.getComponent(CrudHeader) };
}

beforeEach(() => {
  apiMocks.create.mockReset().mockResolvedValue(savedUser);
  apiMocks.get.mockReset().mockResolvedValue(savedUser);
  apiMocks.listGroups.mockReset().mockResolvedValue([]);
  vi.spyOn(window, 'confirm').mockReturnValue(false);
  vi.spyOn(window, 'alert').mockImplementation(() => {});
});

afterEach(() => {
  wrapper?.unmount();
  wrapper = null;
  serverStateQueryClient.clear();
  useNavigationStack().reset();
});

describe('new user save navigation', () => {
  it.each([false, true])('opens the saved user without a warning (stacked: %s)', async (stacked) => {
    const { router, view, header } = await mountNewUser(stacked);
    expect(header.props('dirty')).toBe(true);

    header.vm.$emit('save');
    await flushPromises();

    expect(apiMocks.create).toHaveBeenCalledWith(
      '/api/ash/users',
      'users',
      {
        username: 'new-user',
        is_admin: false,
        groups: [],
        password,
        password_confirmation: password,
      },
      new URLSearchParams({ include: 'groups' })
    );
    expect(window.confirm).not.toHaveBeenCalled();
    expect(router.currentRoute.value.path).toBe('/administration/users/123');
    expect(header.props('dirty')).toBe(false);
    expect(view.findAll('input[type="password"]').map((input) => (input.element as HTMLInputElement).value))
      .toEqual(['', '']);
  });

  it('keeps the draft protected while saving and after a failed save', async () => {
    let rejectSave!: (error: Error) => void;
    apiMocks.create.mockImplementation(() => new Promise((_resolve, reject) => { rejectSave = reject; }));
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const { router, view, header } = await mountNewUser();
    header.vm.$emit('save');
    await flushPromises();

    await router.push('/administration/users');
    expect(window.confirm).toHaveBeenLastCalledWith(warning);
    expect(router.currentRoute.value.path).toBe('/administration/users/new');

    rejectSave(new Error('Save failed'));
    await flushPromises();

    expect(header.props('dirty')).toBe(true);
    expect(header.props('saving')).toBe(false);
    expect(view.findAll('input[type="password"]').map((input) => (input.element as HTMLInputElement).value))
      .toEqual([password, password]);
    await router.push('/administration/users');
    expect(window.confirm).toHaveBeenCalledTimes(2);
    expect(router.currentRoute.value.path).toBe('/administration/users/new');
  });
});
