<template>
  <div class="chat-search-field">
    <input
      v-model="term" type="search" class="full" :placeholder="label" :aria-label="label"
      :title="ordered ? orderedHint : t('Match word prefixes in any order. Use at least 3 letters or digits per word.')"
      @keydown.enter="submit"
    />
    <button
      type="button" class="search-icon-button chat-search-order" :class="{ active: ordered }"
      :aria-pressed="ordered" :title="orderedHint" @click="ordered = !ordered"
    >{{ t('Words in order') }}</button>
    <SearchClearButton v-if="term" @click="term = ''" />
    <slot />
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import SearchClearButton from '@/components/SearchClearButton.vue';
import { translate as t } from '@/i18n';

defineProps<{ label: string }>();
const term = defineModel<string>({ required: true });
const ordered = defineModel<boolean>('ordered', { required: true });
const emit = defineEmits<{ submit: [] }>();
const orderedHint = computed(() => t('Match consecutive word prefixes. Words shorter than 3 characters must match in full.'));
function submit(event: KeyboardEvent) {
  if (!event.isComposing) { event.preventDefault(); emit('submit'); }
}
</script>

<style scoped>
.chat-search-field { display: flex; align-items: center; gap: 8px; }
.chat-search-field input { flex: 1; min-width: 0; }
.chat-search-order { width: auto; padding: 0 8px; white-space: nowrap; font-size: 0.84rem; }
</style>
