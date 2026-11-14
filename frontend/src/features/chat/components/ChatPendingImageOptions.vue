<template>
  <!-- Clicks and keys stay here: the attachment row itself opens the preview. -->
  <div class="pending-image-options" @click.stop @keydown.stop>
    <label
      class="pending-image-options__toggle"
      :class="{ 'pending-image-options__toggle--disabled': toggleDisabled }"
      :title="summary.toggleTitle"
    >
      <input
        type="checkbox"
        :checked="summary.originalChecked"
        :disabled="toggleDisabled"
        @change="emit('update:keepOriginal', ($event.target as HTMLInputElement).checked)"
      />
      <span>{{ t('Original') }}</span>
    </label>
    <span
      v-if="summary.note"
      class="pending-image-options__note"
      :class="{ 'pending-image-options__note--warning': summary.warning }"
      data-i18n-ignore
    >{{ summary.note }}</span>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import { describePendingImage, type PendingImageState } from '@/features/chat/attachments';
import { translate as t } from '@/i18n';

interface Props {
  image: PendingImageState;
  disabled?: boolean;
}

const props = withDefaults(defineProps<Props>(), {
  disabled: false,
});

const emit = defineEmits<{
  (e: 'update:keepOriginal', value: boolean): void;
}>();

const summary = computed(() => describePendingImage(props.image));
const toggleDisabled = computed(() => props.disabled || summary.value.toggleDisabled);
</script>

<style scoped>
.pending-image-options {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 2px 8px;
  min-width: 0;
  font-size: 0.72rem;
  line-height: 1.25;
  color: var(--color-text-muted);
  cursor: default;
}

.pending-image-options__toggle {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  flex: 0 0 auto;
  font-size: inherit;
  color: var(--color-text);
  cursor: pointer;
  user-select: none;
}

.pending-image-options__toggle input {
  width: 12px;
  height: 12px;
  margin: 0;
  cursor: inherit;
}

.pending-image-options__toggle--disabled {
  color: var(--color-text-subtle);
  cursor: default;
}

.pending-image-options__note {
  min-width: 0;
  overflow-wrap: anywhere;
}

.pending-image-options__note--warning {
  color: var(--color-warning-text);
}
</style>
