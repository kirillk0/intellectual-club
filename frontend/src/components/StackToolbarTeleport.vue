<template>
  <Teleport v-if="isActive" to="#toolbar-host">
    <slot />
  </Teleport>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import { Teleport } from 'vue';
import { useStackLayer } from '@/features/stack/useStackLayer';

const layer = useStackLayer();
const isActive = computed(() => layer.active.value);
</script>
