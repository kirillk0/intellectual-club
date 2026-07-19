import { flushPromises, mount } from '@vue/test-utils';
import { VueQueryPlugin } from '@tanstack/vue-query';
import { defineComponent, h, nextTick, onMounted } from 'vue';
import { createMemoryHistory, createRouter, useRoute } from 'vue-router';

const jsonApiMocks = vi.hoisted(() => ({
  get: vi.fn(),
}));

vi.mock('@/api/jsonApi', async () => {
  const actual = await vi.importActual<typeof import('@/api/jsonApi')>('@/api/jsonApi');
  return {
    ...actual,
    jsonApiGet: jsonApiMocks.get,
  };
});

import StackRouterView from '@/components/StackRouterView.vue';
import { useCrudEditor } from '@/features/catalogs/model/useCrudEditor';
import { useEditorTabState } from '@/features/catalogs/model/useEditorUiState';
import { serverStateQueryClient } from '@/features/serverState/queryClient';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { useStackLayer } from '@/features/stack/useStackLayer';

describe('StackRouterView entity identity', () => {
  beforeEach(() => {
    jsonApiMocks.get.mockReset();
    serverStateQueryClient.clear();
    useNavigationStack().reset();
  });

  afterEach(() => {
    serverStateQueryClient.clear();
  });

  it('remounts opted-in editors for entity changes but not query changes', async () => {
    let mountCount = 0;
    const Editor = defineComponent({
      setup() {
        const tab = useEditorTabState<'first' | 'second'>('stack-router-view-test', 'first');
        onMounted(() => {
          mountCount += 1;
        });
        return () => h('button', { onClick: () => { tab.value = 'second'; } }, tab.value);
      },
    });
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [
        {
          path: '/items/:id',
          name: 'item-editor',
          component: Editor,
          meta: { stackEntityParams: ['id'] },
        },
      ],
    });

    await router.push('/items/1');
    await router.isReady();
    const wrapper = mount(StackRouterView, { global: { plugins: [router] } });
    await flushPromises();
    expect(mountCount).toBe(1);

    await wrapper.get('button').trigger('click');
    expect(wrapper.text()).toContain('second');

    await router.replace('/items/2');
    await flushPromises();
    expect(mountCount).toBe(2);
    expect(wrapper.text()).toContain('second');

    await router.replace('/items/2?panel=details');
    await flushPromises();
    expect(mountCount).toBe(2);

    wrapper.unmount();
  });

  it('keeps the previous layer presented and interactive until the destination is ready', async () => {
    let setDestinationReady!: (ready: boolean) => void;
    const List = defineComponent({
      setup: () => () => h('div', { 'data-testid': 'list' }, 'List'),
    });
    const Editor = defineComponent({
      setup() {
        const layer = useStackLayer();
        setDestinationReady = layer.setReady;
        setDestinationReady(false);
        return () => h('div', { 'data-testid': 'editor' }, 'Editor');
      },
    });
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [
        { path: '/items', component: List },
        { path: '/items/:id', component: Editor },
      ],
    });

    await router.push('/items');
    await router.isReady();
    const wrapper = mount(StackRouterView, { global: { plugins: [router] } });
    await flushPromises();

    useNavigationStack().markPendingPush(0);
    await router.push('/items/1');
    await flushPromises();

    const presentedLayer = wrapper.get('.stack-layer--active');
    const pendingLayer = wrapper.get('.stack-layer--inactive');
    expect(presentedLayer.find('[data-testid="list"]').exists()).toBe(true);
    expect(presentedLayer.attributes('inert')).toBeUndefined();
    expect(pendingLayer.find('[data-testid="editor"]').exists()).toBe(true);
    expect(pendingLayer.attributes('inert')).toBeDefined();
    expect(wrapper.get('.stack-nav').attributes('aria-busy')).toBe('true');

    setDestinationReady(true);
    await nextTick();

    expect(wrapper.get('.stack-layer--active').find('[data-testid="editor"]').exists()).toBe(true);
    expect(wrapper.get('.stack-nav').attributes('aria-busy')).toBe('false');

    setDestinationReady(false);
    await nextTick();
    expect(wrapper.get('.stack-layer--active').find('[data-testid="editor"]').exists()).toBe(true);

    await router.replace('/items/2');
    await flushPromises();
    expect(wrapper.get('.stack-layer--active').find('[data-testid="list"]').exists()).toBe(true);
    expect(wrapper.get('.stack-nav').attributes('aria-busy')).toBe('true');

    setDestinationReady(true);
    await nextTick();
    expect(wrapper.get('.stack-layer--active').find('[data-testid="editor"]').exists()).toBe(true);

    wrapper.unmount();
  });

  it('keeps an unmanaged reused layer presented when its route params change', async () => {
    const List = defineComponent({
      setup: () => () => h('div', { 'data-testid': 'list' }, 'List'),
    });
    const Detail = defineComponent({
      setup() {
        const route = useRoute();
        return () => h('div', { 'data-testid': 'detail' }, `Detail ${route.params.id}`);
      },
    });
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [
        { path: '/items', component: List },
        { path: '/items/:id', component: Detail },
      ],
    });

    await router.push('/items');
    await router.isReady();
    const wrapper = mount(StackRouterView, { global: { plugins: [router] } });
    await flushPromises();

    useNavigationStack().markPendingPush(0);
    await router.push('/items/1');
    await flushPromises();
    expect(wrapper.get('.stack-layer--active').find('[data-testid="detail"]').text()).toBe('Detail 1');

    await router.replace('/items/2');
    await flushPromises();

    expect(wrapper.get('.stack-layer--active').find('[data-testid="detail"]').text()).toBe('Detail 2');
    expect(wrapper.get('.stack-nav').attributes('aria-busy')).toBe('false');

    wrapper.unmount();
  });

  it('presents an ordinary editor while its document is still loading', async () => {
    jsonApiMocks.get.mockReturnValue(new Promise(() => undefined));

    const List = defineComponent({
      setup: () => () => h('div', { 'data-testid': 'list' }, 'List'),
    });
    const Editor = defineComponent({
      setup() {
        const editor = useCrudEditor({
          type: 'test-items',
          basePath: '/api/test-items',
          indexPath: '/items',
          editPath: (id) => `/items/${id}`,
          defaultForm: () => ({ name: '' }),
          fromApi: (resource) => ({ name: String(resource.attributes?.name || '') }),
          toAttributes: (form) => ({ name: form.name }),
        });

        return () =>
          h(
            'div',
            { 'data-testid': 'editor-loading' },
            editor.loading.value ? 'Loading' : 'Loaded'
          );
      },
    });
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [
        { path: '/items', component: List },
        { path: '/items/:id', component: Editor },
      ],
    });

    await router.push('/items');
    await router.isReady();
    const wrapper = mount(StackRouterView, {
      global: {
        plugins: [
          router,
          [VueQueryPlugin, { queryClient: serverStateQueryClient }],
        ],
      },
    });
    await flushPromises();

    useNavigationStack().markPendingPush(0);
    await router.push('/items/1');
    await vi.waitFor(() => expect(jsonApiMocks.get).toHaveBeenCalledTimes(1));

    const presentedLayer = wrapper.get('.stack-layer--active');
    expect(presentedLayer.find('[data-testid="editor-loading"]').text()).toBe('Loading');
    expect(presentedLayer.attributes('inert')).toBeUndefined();
    expect(wrapper.get('.stack-nav').attributes('aria-busy')).toBe('false');

    wrapper.unmount();
  });
});
