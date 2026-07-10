import { flushPromises, mount } from '@vue/test-utils';
import { defineComponent, h, onMounted } from 'vue';
import { createMemoryHistory, createRouter } from 'vue-router';

import StackRouterView from '@/components/StackRouterView.vue';
import { useEditorTabState } from '@/features/catalogs/model/useEditorUiState';
import { useNavigationStack } from '@/features/stack/navigationStack';

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
});
