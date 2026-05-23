<template>
  <ModalWindow
    :open="open"
    max-width="520px"
    aria-label="Chat note"
    :cancel-disabled="saving"
    :submit-disabled="saving"
    submit-shortcut="auto"
    @cancel="emit('cancel')"
    @submit="emit('save')"
  >
    <h3 style="margin: 0">Chat note</h3>
    <div class="stack">
      <label class="stack" style="gap: 6px">
        <span class="muted">Shown in the chat list after the bot name.</span>
        <input
          type="text"
          v-model="note"
          placeholder="Add a short note"
          maxlength="255"
          autocomplete="off"
        />
      </label>
    </div>
    <div class="modal-actions">
      <div class="spacer"></div>
      <button type="button" @click="emit('cancel')" :disabled="saving">Cancel</button>
      <button class="primary" type="button" @click="emit('save')" :disabled="saving">
        {{ saving ? 'Saving…' : 'Save' }}
      </button>
    </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import ModalWindow from '@/components/ModalWindow.vue';

interface Props {
  open: boolean;
  modelValue: string;
  saving?: boolean;
}

const props = defineProps<Props>();
const emit = defineEmits<{
  (e: 'update:modelValue', value: string): void;
  (e: 'cancel'): void;
  (e: 'save'): void;
}>();

const note = computed({
  get: () => props.modelValue,
  set: (value: string) => emit('update:modelValue', value),
});

const saving = computed(() => Boolean(props.saving));
</script>
