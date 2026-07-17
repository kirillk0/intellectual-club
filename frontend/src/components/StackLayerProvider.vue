<template>
  <slot />
</template>

<script setup lang="ts">
import { onMounted, provide, shallowReactive, toRef, watch } from 'vue';
import { routeLocationKey, type RouteLocationNormalizedLoaded } from 'vue-router';
import { invalidateServerStateQueries } from '@/features/serverState/queryClient';
import { provideStackLayer } from '@/features/stack/useStackLayer';

const props = defineProps<{
  active: boolean;
  presented: boolean;
  depth: number;
  route: RouteLocationNormalizedLoaded;
}>();
const emit = defineEmits<{
  readyChange: [ready: boolean];
}>();

const layerRoute = shallowReactive({} as RouteLocationNormalizedLoaded);
let readinessManaged = false;

const setReady = (ready: boolean) => {
  readinessManaged = true;
  emit('readyChange', ready);
};

watch(
  () => props.route.fullPath,
  () => {
    Object.assign(layerRoute, props.route);
  },
  { immediate: true }
);

watch(
  () => props.active,
  (active, wasActive) => {
    if (active && wasActive === false) void invalidateServerStateQueries();
  }
);

onMounted(() => {
  if (!readinessManaged) emit('readyChange', true);
});

provideStackLayer({
  active: toRef(props, 'active'),
  presented: toRef(props, 'presented'),
  depth: toRef(props, 'depth'),
  setReady,
});

provide(routeLocationKey, layerRoute);
</script>
