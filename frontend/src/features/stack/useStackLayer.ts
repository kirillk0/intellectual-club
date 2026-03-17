import { inject, provide, ref, type Ref } from 'vue';

type StackLayerContext = {
  active: Ref<boolean>;
  depth: Ref<number>;
};

const STACK_LAYER_CONTEXT = Symbol('stack-layer');

export const provideStackLayer = (context: StackLayerContext) => {
  provide(STACK_LAYER_CONTEXT, context);
};

export const useStackLayer = () =>
  inject(STACK_LAYER_CONTEXT, {
    active: ref(true),
    depth: ref(0),
  });

export type { StackLayerContext };

