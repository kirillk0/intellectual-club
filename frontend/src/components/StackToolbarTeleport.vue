<template>
  <Teleport v-if="isPresented" to="#toolbar-host">
    <div class="stack-toolbar-content" :inert="!isInteractive">
      <slot />
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import { Teleport } from 'vue';
import { useStackLayer } from '@/features/stack/useStackLayer';

const layer = useStackLayer();
const isPresented = computed(() => layer.presented.value);
const isInteractive = computed(() => layer.active.value && layer.presented.value);
</script>

<style>
.stack-toolbar-content {
  display: contents;
}

.stack-toolbar-content > * {
  min-width: 0;
}
</style>
