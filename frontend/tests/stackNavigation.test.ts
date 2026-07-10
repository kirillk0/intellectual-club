import type { RouteLocationNormalizedLoaded } from 'vue-router';

const routerMocks = vi.hoisted(() => ({
  push: vi.fn(),
  replace: vi.fn(),
  back: vi.fn(),
}));

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router');
  return {
    ...actual,
    useRouter: () => routerMocks,
  };
});

import { useNavigationStack } from '@/features/stack/navigationStack';
import { useStackNavigation } from '@/features/stack/useStackNavigation';

const route = (fullPath: string): RouteLocationNormalizedLoaded =>
  ({
    fullPath,
    path: fullPath,
    name: undefined,
    params: {},
    query: {},
    hash: '',
    matched: [],
    meta: {},
    redirectedFrom: undefined,
  }) as RouteLocationNormalizedLoaded;

describe('navigation stack results', () => {
  const stack = useNavigationStack();

  beforeEach(() => {
    stack.reset();
    routerMocks.push.mockReset();
    routerMocks.replace.mockReset();
    routerMocks.back.mockReset();
  });

  it('completes an opened layer with its explicitly assigned result on pop', async () => {
    const { controller, promise } = stack.createResultController<{ id: number }>();

    stack.markPendingPush(120, controller);
    stack.commitPendingPush(route('/parent'));
    expect(stack.setLayerResult({ id: 42 })).toBe(true);

    const entry = stack.pop();

    expect(entry?.scrollY).toBe(120);
    await expect(promise).resolves.toEqual({ status: 'completed', value: { id: 42 } });
  });

  it('cancels a result when the browser pops a layer without a value', async () => {
    const { controller, promise } = stack.createResultController<number>();

    stack.markPendingPush(0, controller);
    stack.commitPendingPush(route('/parent'));
    stack.pop();

    await expect(promise).resolves.toEqual({ status: 'cancelled' });
  });

  it('cancels active and pending result requests on reset', async () => {
    const activeResult = stack.createResultController<number>();
    const pendingResult = stack.createResultController<string>();

    stack.markPendingPush(0, activeResult.controller);
    stack.commitPendingPush(route('/parent'));
    stack.markPendingPush(0, pendingResult.controller);
    stack.reset();

    await expect(activeResult.promise).resolves.toEqual({ status: 'cancelled' });
    await expect(pendingResult.promise).resolves.toEqual({ status: 'cancelled' });
    expect(stack.stack.value).toEqual([]);
    expect(stack.pendingPush.value).toBeNull();
  });

  it('does not let an older failed navigation clear a newer pending push', async () => {
    const firstResult = stack.createResultController<number>();
    const secondResult = stack.createResultController<number>();
    const firstId = stack.markPendingPush(0, firstResult.controller);
    const secondId = stack.markPendingPush(0, secondResult.controller);

    expect(stack.cancelPendingPush(firstId)).toBe(false);
    expect(stack.pendingPush.value?.id).toBe(secondId);
    await expect(firstResult.promise).resolves.toEqual({ status: 'cancelled' });

    expect(stack.cancelPendingPush(secondId)).toBe(true);
    await expect(secondResult.promise).resolves.toEqual({ status: 'cancelled' });
  });

  it('clears pending state and cancels openForResult on NavigationFailure', async () => {
    const failure = Object.assign(new Error('duplicated navigation'), {
      type: 16,
      from: route('/parent'),
      to: route('/child'),
    });
    routerMocks.push.mockResolvedValue(failure);
    const navigation = useStackNavigation();

    const result = await navigation.openForResult<number>('/child');

    expect(result).toEqual({ status: 'cancelled' });
    expect(stack.pendingPush.value).toBeNull();
    expect(stack.stack.value).toEqual([]);
  });

  it('connects the public typed result API to the active child layer', async () => {
    routerMocks.push.mockImplementation(async () => {
      stack.commitPendingPush(route('/parent'));
    });
    const navigation = useStackNavigation();

    const resultPromise = navigation.openForResult<{ id: number }>('/child');
    await vi.waitFor(() => expect(stack.active.value).toBe(true));
    expect(navigation.setLayerResult({ id: 7 })).toBe(true);
    stack.pop();

    await expect(resultPromise).resolves.toEqual({ status: 'completed', value: { id: 7 } });
  });

  it('accumulates multiple updateLayerResult changes without losing earlier values', async () => {
    type LayerResult = { changes: Array<{ id: number; operation: 'upsert' | 'delete' }> };
    routerMocks.push.mockImplementation(async () => {
      stack.commitPendingPush(route('/parent'));
    });
    const navigation = useStackNavigation();

    const resultPromise = navigation.openForResult<LayerResult>('/child');
    await vi.waitFor(() => expect(stack.active.value).toBe(true));

    expect(
      navigation.updateLayerResult<LayerResult>((current) => ({
        changes: [...(current?.changes || []), { id: 1, operation: 'upsert' }],
      }))
    ).toBe(true);
    expect(
      navigation.updateLayerResult<LayerResult>((current) => ({
        changes: [...(current?.changes || []), { id: 2, operation: 'delete' }],
      }))
    ).toBe(true);
    stack.pop();

    await expect(resultPromise).resolves.toEqual({
      status: 'completed',
      value: {
        changes: [
          { id: 1, operation: 'upsert' },
          { id: 2, operation: 'delete' },
        ],
      },
    });
  });
});
