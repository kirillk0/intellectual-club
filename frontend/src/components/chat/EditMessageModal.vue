<template>
  <transition name="fade">
    <div v-if="open" class="modal-backdrop">
      <div class="modal" role="dialog" aria-modal="true" aria-label="Edit message">
        <h3 style="margin: 0">Edit message</h3>
        <textarea v-model="content" rows="8" autofocus></textarea>
        <div class="modal-actions">
          <span v-if="errorText" class="error-text">{{ errorText }}</span>
          <div class="spacer"></div>
          <button
            class="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm font-medium text-zinc-900 transition hover:bg-zinc-50 disabled:opacity-50"
            type="button"
            @click="emit('cancel')"
            :disabled="saving"
          >
            Cancel
          </button>
          <button
            class="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white transition hover:bg-zinc-800 disabled:opacity-50"
            type="button"
            @click="emit('save')"
            :disabled="saving"
          >
            {{ confirmLabel }}
          </button>
        </div>
      </div>
    </div>
  </transition>
</template>

<script setup lang="ts">
import { computed } from 'vue';

interface Props {
  open: boolean;
  modelValue: string;
  error?: string;
  saving?: boolean;
}

const props = defineProps<Props>();
const emit = defineEmits<{
  (e: 'update:modelValue', value: string): void;
  (e: 'cancel'): void;
  (e: 'save'): void;
}>();

const content = computed({
  get: () => props.modelValue,
  set: (value: string) => emit('update:modelValue', value),
});

const saving = computed(() => Boolean(props.saving));
const errorText = computed(() => (props.error || '').trim());
const confirmLabel = computed(() => (saving.value ? 'Saving…' : 'Save'));
</script>
