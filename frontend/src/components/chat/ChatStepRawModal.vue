<template>
  <ModalWindow
    :open="open"
    max-width="900px"
    :aria-label="title || 'Payload'"
    @cancel="emit('close')"
  >
    <h3 style="margin: 0">{{ title || 'Payload' }}</h3>
    <div v-if="loading" class="muted" style="margin-top: 8px">Loading payload…</div>
    <div v-else-if="errorText" class="error-text" style="margin-top: 8px">{{ errorText }}</div>
    <pre
      v-else
      class="code-block"
      style="
        white-space: pre-wrap;
        word-break: break-word;
        max-height: 65vh;
        overflow: auto;
        margin-top: 8px;
      "
    >{{ textValue || '—' }}</pre>
    <div class="modal-actions">
      <div class="spacer"></div>
      <button type="button" @click="emit('close')">Close</button>
    </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import ModalWindow from '@/components/ModalWindow.vue';

interface Props {
  open: boolean;
  title?: string;
  loading?: boolean;
  error?: string;
  text?: string;
}

const props = defineProps<Props>();
const emit = defineEmits<{ (e: 'close'): void }>();

const loading = computed(() => Boolean(props.loading));
const errorText = computed(() => (props.error || '').trim());
const textValue = computed(() => props.text ?? '');
const title = computed(() => props.title ?? '');
</script>
