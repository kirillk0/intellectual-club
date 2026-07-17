import { flushPromises, mount } from '@vue/test-utils';
import { defineComponent, h, nextTick, onMounted } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

import StackRouterView from '@/components/StackRouterView.vue';
import { useEditorTabState } from '@/features/catalogs/model/useEditorUiState';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { useStackLayer } from '@/features/stack/useStackLayer';

describe('StackRouterView entity identity', () => {
  beforeEach(() => {
    useNavigationStack().reset();
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

  it('keeps the previous layer presented until the destination is ready', async () => {
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

    expect(wrapper.get('.stack-layer--active').find('[data-testid="list"]').exists()).toBe(true);
    expect(wrapper.get('.stack-layer--inactive').find('[data-testid="editor"]').exists()).toBe(true);
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
});
