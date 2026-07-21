import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { VueQueryPlugin } from '@tanstack/vue-query';
import { defineComponent, h, nextTick, ref } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

const jsonApiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  remove: vi.fn(),
}));

vi.mock('@/api/jsonApi', async () => {
  const actual = await vi.importActual<typeof import('@/api/jsonApi')>('@/api/jsonApi');
  return {
    ...actual,
    jsonApiGet: jsonApiMocks.get,
    jsonApiDelete: jsonApiMocks.remove,
  };
});

import type { JsonApiSingleResponse } from '@/api/jsonApi';
import { useCrudEditor } from '@/features/catalogs/model/useCrudEditor';
import { useNavigationStack } from '@/features/stack/navigationStack';
import {
  SERVER_STATE_QUERY_ROOT,
  serverStateKeys,
  serverStateQueryClient,
} from '@/features/serverState/queryClient';

type TestForm = {
  name: string;
};

function document(id: number, name: string): JsonApiSingleResponse {
  return {
    data: {
      id: String(id),
      type: 'test-items',
      attributes: { name },
    },
  };
}

function useTestEditor() {
  return useCrudEditor<TestForm>({
    type: 'test-items',
    basePath: '/api/test-items',
    indexPath: '/items',
    editPath: (id) => `/items/${id}`,
    defaultForm: () => ({ name: '' }),
    fromApi: (resource) => ({ name: String(resource.attributes?.name || '') }),
    toAttributes: (form) => ({ name: form.name }),
  });
}

type TestEditor = ReturnType<typeof useTestEditor>;

let activeWrapper: VueWrapper | null = null;

async function mountEditor(path = '/items/1', stackedFrom?: string) {
  serverStateQueryClient.clear();
  const stack = useNavigationStack();
  stack.reset();

  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/items', component: { template: '<div />' } },
      { path: '/items/:id', component: { template: '<div />' } },
    ],
  });
  if (stackedFrom) {
    await router.push(stackedFrom);
    await router.isReady();
    const parentRoute = router.currentRoute.value;
    stack.markPendingPush(0);
    await router.push(path);
    stack.commitPendingPush(parentRoute);
  } else {
    await router.push(path);
    await router.isReady();
  }

  let editor!: TestEditor;
  const Harness = defineComponent({
    setup() {
      editor = useTestEditor();
      return () => h('div');
    },
  });

  activeWrapper = mount(Harness, {
    global: {
      plugins: [router, [VueQueryPlugin, { queryClient: serverStateQueryClient }]],
    },
  });

  return { editor, router };
}

describe('useCrudEditor canonical documents', () => {
  beforeEach(() => {
    jsonApiMocks.get.mockReset();
    jsonApiMocks.remove.mockReset();
  });

  afterEach(() => {
    activeWrapper?.unmount();
    activeWrapper = null;
    serverStateQueryClient.clear();
    useNavigationStack().reset();
  });

  it('does not let a late response for id 1 overwrite the form for id 2', async () => {
    const pending: Array<{
      id: number;
      signal?: AbortSignal;
      resolve: (payload: JsonApiSingleResponse) => void;
    }> = [];
    jsonApiMocks.get.mockImplementation(
      (path: string, _params?: URLSearchParams, options?: { signal?: AbortSignal }) =>
        new Promise<JsonApiSingleResponse>((resolve) => {
          const id = Number(path.split('/').at(-1));
          pending.push({ id, signal: options?.signal, resolve });
        })
    );

    const { editor, router } = await mountEditor();
    await vi.waitFor(() => expect(pending.map((request) => request.id)).toEqual([1]));

    await router.replace('/items/2');
    await vi.waitFor(() => expect(pending.map((request) => request.id)).toEqual([1, 2]));
    expect(pending[0]?.signal?.aborted).toBe(true);

    pending[1]?.resolve(document(2, 'Second'));
    await flushPromises();
    expect(editor.numericId.value).toBe(2);
    expect(editor.form.name).toBe('Second');

    pending[0]?.resolve(document(1, 'First, but late'));
    await flushPromises();
    expect(editor.numericId.value).toBe(2);
    expect(editor.form.name).toBe('Second');
  });

  it('replaces a stacked editor when creating a record so close returns to the list', async () => {
    jsonApiMocks.get.mockResolvedValue(document(1, 'Initial'));
    const { editor, router } = await mountEditor('/items/1', '/items');
    await vi.waitFor(() => expect(editor.loaded.value).toBe(true));
    const stack = useNavigationStack();
    expect(stack.top.value?.route.fullPath).toBe('/items');

    await editor.createNew();
    expect(router.currentRoute.value.fullPath).toBe('/items/new');
    expect(stack.stack.value).toHaveLength(1);
    expect(stack.pendingPush.value).toBeNull();

    editor.goList();
    await vi.waitFor(() => expect(router.currentRoute.value.fullPath).toBe('/items'));
  });

  it('applies a cached document after the parent setup has initialized its document handlers', async () => {
    serverStateQueryClient.clear();
    useNavigationStack().reset();
    serverStateQueryClient.setQueryData(
      serverStateKeys.detail('test-items', 1, 'editor-document'),
      document(1, 'Cached')
    );
    jsonApiMocks.get.mockResolvedValue(document(1, 'Cached'));

    const router = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/items/:id', component: { template: '<div />' } }],
    });
    await router.push('/items/1');
    await router.isReady();

    let documentHandlerCalled = false;
    const Harness = defineComponent({
      setup() {
        useCrudEditor<TestForm>({
          type: 'test-items',
          basePath: '/api/test-items',
          indexPath: '/items',
          editPath: (id) => `/items/${id}`,
          defaultForm: () => ({ name: '' }),
          fromApi: (resource) => ({ name: String(resource.attributes?.name || '') }),
          toAttributes: (form) => ({ name: form.name }),
          onDocument: () => {
            lateSetupDependency.value = true;
            documentHandlerCalled = true;
          },
        });
        const lateSetupDependency = ref(false);
        return () => h('div', String(lateSetupDependency.value));
      },
    });

    activeWrapper = mount(Harness, {
      global: {
        plugins: [router, [VueQueryPlugin, { queryClient: serverStateQueryClient }]],
      },
    });

    await flushPromises();
    expect(documentHandlerCalled).toBe(true);
    expect(activeWrapper.text()).toBe('true');
  });

  it('rebases a clean form when its canonical cache document changes', async () => {
    jsonApiMocks.get.mockResolvedValue(document(1, 'Initial'));
    const { editor } = await mountEditor();
    await vi.waitFor(() => expect(editor.loaded.value).toBe(true));

    serverStateQueryClient.setQueryData(
      serverStateKeys.detail('test-items', 1, 'editor-document'),
      document(1, 'Updated remotely')
    );
    await flushPromises();

    expect(editor.form.name).toBe('Updated remotely');
    expect(editor.base.value.name).toBe('Updated remotely');
    expect(editor.dirty.value).toBe(false);
    expect(editor.remoteUpdateAvailable.value).toBe(false);
  });

  it('keeps a dirty draft, reports a remote update, and reloads the server version', async () => {
    const initial = document(1, 'Initial');
    const remote = document(1, 'Updated remotely');
    jsonApiMocks.get.mockResolvedValue(initial);
    const { editor } = await mountEditor();
    await vi.waitFor(() => expect(editor.loaded.value).toBe(true));

    editor.form.name = 'Local draft';
    await nextTick();
    expect(editor.dirty.value).toBe(true);

    serverStateQueryClient.setQueryData(
      serverStateKeys.detail('test-items', 1, 'editor-document'),
      remote
    );
    await flushPromises();

    expect(editor.form.name).toBe('Local draft');
    expect(editor.base.value.name).toBe('Initial');
    expect(editor.remoteUpdateAvailable.value).toBe(true);

    jsonApiMocks.get.mockResolvedValue(remote);
    await editor.reloadRemoteDocument();
    await flushPromises();

    expect(editor.form.name).toBe('Updated remotely');
    expect(editor.base.value.name).toBe('Updated remotely');
    expect(editor.dirty.value).toBe(false);
    expect(editor.remoteUpdateAvailable.value).toBe(false);
  });

  it('disables the deleted detail before broad invalidation can refetch it', async () => {
    jsonApiMocks.get.mockResolvedValue(document(1, 'Initial'));
    let completeDelete!: () => void;
    jsonApiMocks.remove.mockImplementation(
      () => new Promise<void>((resolve) => {
        completeDelete = resolve;
      })
    );
    vi.spyOn(window, 'confirm').mockReturnValue(true);

    const { editor } = await mountEditor();
    await vi.waitFor(() => expect(editor.loaded.value).toBe(true));
    jsonApiMocks.get.mockClear();

    const removing = editor.remove();
    await vi.waitFor(() => expect(editor.deleting.value).toBe(true));
    await serverStateQueryClient.invalidateQueries({
      queryKey: SERVER_STATE_QUERY_ROOT,
      refetchType: 'active',
    });

    expect(jsonApiMocks.get).not.toHaveBeenCalled();

    completeDelete();
    await removing;
    expect(editor.deleting.value).toBe(true);
  });
});
