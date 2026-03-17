<template>
  <slot />
</template>

<script setup lang="ts">
import { provide, shallowReactive, toRef, watch } from 'vue';
import { routeLocationKey, type RouteLocationNormalizedLoaded } from 'vue-router';
import { provideStackLayer } from '@/features/stack/useStackLayer';

const props = defineProps<{ active: boolean; depth: number; route: RouteLocationNormalizedLoaded }>();

const layerRoute = shallowReactive({} as RouteLocationNormalizedLoaded);

watch(
  () => props.route.fullPath,
  () => {
    Object.assign(layerRoute, props.route);
  },
  { immediate: true }
);

provideStackLayer({
  active: toRef(props, 'active'),
  depth: toRef(props, 'depth'),
});

provide(routeLocationKey, layerRoute);
</script>

