<template>
  <transition name="fade">
    <div v-if="open" class="modal-backdrop" @click.self="emit('close')">
      <div class="modal" style="max-width: 820px">
        <h3 style="margin: 0">Prompt</h3>
        <div v-if="loading" class="muted">Loading prompt…</div>
        <div v-else-if="errorText" class="error-text">{{ errorText }}</div>
        <pre
          v-else
          class="code-block"
          style="white-space: pre-wrap; word-break: break-word; max-height: 60vh; overflow: auto"
        >{{ promptText || '—' }}</pre>
        <div class="modal-actions">
          <div class="spacer"></div>
          <button type="button" @click="emit('close')">Close</button>
        </div>
      </div>
    </div>
  </transition>
</template>

<script setup lang="ts">
import { computed } from 'vue';

interface Props {
  open: boolean;
  loading?: boolean;
  error?: string;
  text?: string;
}

const props = defineProps<Props>();
const emit = defineEmits<{ (e: 'close'): void }>();

const loading = computed(() => Boolean(props.loading));
const errorText = computed(() => (props.error || '').trim());
const promptText = computed(() => props.text ?? '');
</script>

