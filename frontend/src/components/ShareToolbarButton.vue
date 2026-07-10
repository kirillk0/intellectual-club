<template>
  <button
    class="icon-button crud-icon-button share-toolbar-button"
    type="button"
    :aria-label="accessibleLabel"
    :title="accessibleLabel"
    @click="emit('click')"
  >
    <SvgIcon name="share-outgoing" size="16" />
    <span v-if="shared" class="share-toolbar-button__indicator" aria-hidden="true"></span>
  </button>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';

const props = defineProps<{
  shared?: boolean;
}>();

const emit = defineEmits<{
  click: [];
}>();

const accessibleLabel = computed(() =>
  props.shared ? 'Sharing settings. Shared with groups.' : 'Sharing settings'
);
</script>

<style scoped>
.share-toolbar-button {
  position: relative;
}

.share-toolbar-button__indicator {
  position: absolute;
  top: 4px;
  right: 4px;
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--color-info-text);
  box-shadow: 0 0 0 2px var(--color-surface-muted);
  pointer-events: none;
}

.share-toolbar-button:hover .share-toolbar-button__indicator {
  box-shadow: 0 0 0 2px var(--color-surface-hover);
}
</style>
