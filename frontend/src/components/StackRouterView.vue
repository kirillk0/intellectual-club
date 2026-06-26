<template>
  <div class="stack-nav" :class="{ 'stack-nav--active': stackOverlayActive }">
    <div
      v-for="(layer, index) in layers"
      :key="layerKey(layer.route, index)"
      :class="['stack-layer', index === lastIndex ? 'stack-layer--active' : 'stack-layer--inactive']"
      :aria-hidden="index !== lastIndex"
      :inert="index !== lastIndex"
    >
      <RouterView :route="layer.route" v-slot="{ Component }">
        <StackLayerProvider :active="index === lastIndex" :depth="index" :route="layer.route">
          <component :is="Component" />
        </StackLayerProvider>
      </RouterView>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';
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

// Key router views by route record identity (name + matched patterns), so param/query changes
// don't remount the entire view. This preserves editor UI state (e.g. active tabs) when
// paging records or saving new ones.
const routeViewIdentity = (candidate: RouteLocationNormalizedLoaded) => {
  const name = candidate.name == null ? '' : String(candidate.name);
  const matched = candidate.matched.map((record) => `${String(record.name ?? '')}:${record.path}`).join('|');
  return `${name}::${matched}`;
};

const layerKey = (layerRoute: RouteLocationNormalizedLoaded, depth: number) =>
  `${depth}:${routeViewIdentity(layerRoute)}:${depth === lastIndex.value ? props.reopenKey ?? 0 : 0}`;

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
</script>
