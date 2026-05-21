<template>
  <span class="tool-type-badge" :title="label" :aria-label="label">
    <SvgIcon :name="iconName" :size="iconSize" />
    <span v-if="showLabel" class="tool-type-badge__label">{{ label }}</span>
  </span>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { toolTypeIconName, toolTypeLabel } from '@/features/tools/model/toolInstances';
import type { ToolInstanceOption } from '@/types/api';

const props = withDefaults(
  defineProps<{
    type?: string | null;
    typeTitle?: string | null;
    tool?: Pick<ToolInstanceOption, 'type' | 'type_title'> | null;
    showLabel?: boolean;
    iconSize?: number | string;
  }>(),
  {
    type: null,
    typeTitle: null,
    tool: null,
    showLabel: true,
    iconSize: 15,
  }
);

const typeValue = computed(() => props.tool?.type ?? props.type ?? '');
const label = computed(() =>
  toolTypeLabel(props.tool ?? { type: typeValue.value, type_title: props.typeTitle ?? null })
);
const iconName = computed(() => toolTypeIconName(typeValue.value));
</script>

<style scoped>
.tool-type-badge {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  min-width: 0;
  color: inherit;
}

.tool-type-badge__label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
</style>
