<template>
  <div
    class="stack-nav"
    :class="{
      'stack-nav--active': stackOverlayActive,
      'stack-nav--pending': presentedIndex !== lastIndex,
    }"
    :aria-busy="presentedIndex !== lastIndex"
  >
    <div
      v-for="(layer, index) in layers"
      :key="layerKey(layer.route, index)"
      :class="['stack-layer', index === presentedIndex ? 'stack-layer--active' : 'stack-layer--inactive']"
      :aria-hidden="index !== presentedIndex"
      :inert="index === presentedIndex ? undefined : true"
    >
      <RouterView :route="layer.route" v-slot="{ Component }">
        <StackLayerProvider
          :active="index === lastIndex"
          :presented="index === presentedIndex"
          :depth="index"
          :route="layer.route"
          @ready-change="setLayerReady(layer.route, index, $event)"
        >
          <component :is="Component" />
        </StackLayerProvider>
      </RouterView>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, reactive, ref, watch } from 'vue';
import { RouterView, useRoute, type RouteLocationNormalizedLoaded } from 'vue-router';
import StackLayerProvider from '@/components/StackLayerProvider.vue';
import { useNavigationStack } from '@/features/stack/navigationStack';

const props = defineProps<{ reopenKey?: number }>();

const route = useRoute();
const stack = useNavigationStack();
const stackVisible = computed(() => stack.active.value || stack.pendingPush.value !== null);

const cloneRoute = (source: RouteLocationNormalizedLoaded) =>
  ({
    ...source,
    params: { ...(source.params ?? {}) },
    query: { ...(source.query ?? {}) },
  }) as RouteLocationNormalizedLoaded;

const routeIdentity = (candidate: RouteLocationNormalizedLoaded) => {
  const name = candidate.name == null ? '' : String(candidate.name);
  const matched = candidate.matched.map((record) => `${String(record.name ?? '')}:${record.path}`).join('|');
  return `${name}::${candidate.fullPath}::${matched}`;
};

const sameRouteIdentity = (a: RouteLocationNormalizedLoaded, b: RouteLocationNormalizedLoaded) =>
  routeIdentity(a) === routeIdentity(b);

// Entity params opt specific routes into remounting when their edited record changes.
// Other params and query values continue to update the existing component instance.
const routeViewIdentity = (candidate: RouteLocationNormalizedLoaded) => {
  const name = candidate.name == null ? '' : String(candidate.name);
  const matched = candidate.matched.map((record) => `${String(record.name ?? '')}:${record.path}`).join('|');
  const entityParams = (candidate.meta.stackEntityParams ?? []).map((param) => [
    param,
    candidate.params[param] ?? null,
  ]);
  return `${name}::${matched}::${JSON.stringify(entityParams)}`;
};

const layerKey = (layerRoute: RouteLocationNormalizedLoaded, depth: number) =>
  `${depth}:${routeViewIdentity(layerRoute)}:${depth === lastIndex.value ? props.reopenKey ?? 0 : 0}`;

const layerReadinessKey = (layerRoute: RouteLocationNormalizedLoaded, depth: number) => {
  const name = layerRoute.name == null ? '' : String(layerRoute.name);
  const matched = layerRoute.matched
    .map((record) => `${String(record.name ?? '')}:${record.path}`)
    .join('|');
  return `${depth}:${name}:${layerRoute.path}:${matched}:${
    depth === lastIndex.value ? props.reopenKey ?? 0 : 0
  }`;
};

const baseLayer = ref<RouteLocationNormalizedLoaded>(cloneRoute(route));
const needsBaseLayerSync = (candidate: RouteLocationNormalizedLoaded) =>
  !baseLayer.value || !sameRouteIdentity(baseLayer.value, candidate);

watch(
  () => stack.active.value,
  (active) => {
    if (active && stack.stack.value.length) {
      baseLayer.value = cloneRoute(stack.stack.value[0].route);
      return;
    }
    if (!active && stack.pendingPush.value !== null) return;
    if (needsBaseLayerSync(route)) {
      baseLayer.value = cloneRoute(route);
    }
  },
  { immediate: true }
);

watch(
  () => routeIdentity(route),
  () => {
    if (stack.active.value || stack.pendingPush.value !== null) return;
    if (needsBaseLayerSync(route)) {
      baseLayer.value = cloneRoute(route);
    }
  }
);

const layers = computed(() => {
  if (!stackVisible.value) return [{ route: baseLayer.value }];
  if (stack.active.value) {
    return [...stack.stack.value.map((entry) => ({ route: entry.route })), { route }];
  }
  if (sameRouteIdentity(baseLayer.value, route)) {
    return [{ route: baseLayer.value }];
  }
  return [{ route: baseLayer.value }, { route }];
});

const lastIndex = computed(() => layers.value.length - 1);
const stackOverlayActive = computed(() => layers.value.length > 1);
const layerReadiness = reactive(new Map<string, boolean>());
const destinationLayerKey = computed(() => {
  const destination = layers.value[lastIndex.value];
  return destination ? layerReadinessKey(destination.route, lastIndex.value) : '';
});
const destinationReady = computed(
  () => !stackOverlayActive.value || layerReadiness.get(destinationLayerKey.value) === true
);
const presentedIndex = computed(() =>
  destinationReady.value ? lastIndex.value : Math.max(0, lastIndex.value - 1)
);

const setLayerReady = (
  layerRoute: RouteLocationNormalizedLoaded,
  depth: number,
  ready: boolean
) => {
  const key = layerReadinessKey(layerRoute, depth);
  if (ready || layerReadiness.get(key) !== true) layerReadiness.set(key, ready);
};

watch(
  () => layers.value.map((layer, index) => layerReadinessKey(layer.route, index)),
  (currentKeys) => {
    const activeKeys = new Set(currentKeys);
    for (const key of layerReadiness.keys()) {
      if (!activeKeys.has(key)) layerReadiness.delete(key);
    }
  },
  { immediate: true }
);
</script>
