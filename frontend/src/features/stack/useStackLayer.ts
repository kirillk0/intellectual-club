import { inject, provide, ref, type Ref } from 'vue';

type StackLayerContext = {
  active: Ref<boolean>;
  presented: Ref<boolean>;
  depth: Ref<number>;
  setReady: (ready: boolean) => void;
};

const STACK_LAYER_CONTEXT = Symbol('stack-layer');

export const provideStackLayer = (context: StackLayerContext) => {
  provide(STACK_LAYER_CONTEXT, context);
};

export const useStackLayer = () =>
  inject(STACK_LAYER_CONTEXT, {
    active: ref(true),
    presented: ref(true),
    depth: ref(0),
    setReady: (_ready: boolean) => undefined,
  });

export type { StackLayerContext };
