<template>
  <Teleport to="body">
    <div v-if="open" class="modal-backdrop" @click.self="close">
      <div class="modal tool-binding-picker" role="dialog" aria-modal="true">
        <div class="picker-header">
          <strong>{{ title }}</strong>
        </div>

        <div class="stack" style="gap: 12px">
          <label class="stack" style="gap: 6px">
            <span class="muted">Tool</span>
            <select
              :value="toolInstanceId"
              class="full"
              :disabled="saving || loading || !tools.length"
              @change="handleToolSelect"
            >
              <option :value="0">Choose tool…</option>
              <option v-for="tool in tools" :key="tool.id" :value="tool.id">
                {{ tool.name }} ({{ tool.type }})
              </option>
            </select>
          </label>

          <label class="stack" style="gap: 6px">
            <span class="muted">Alias</span>
            <input
              :value="alias"
              class="full"
              :disabled="saving"
              placeholder="e.g. web"
              @input="handleAliasInput"
              @keydown.enter.prevent="confirm"
            />
          </label>

          <p class="muted tool-binding-picker__note">Tools are exposed as <code>alias__function</code>.</p>
          <p v-if="loading" class="muted" style="margin: 0">Loading tools…</p>
          <p v-else-if="error" class="error-text" style="margin: 0">{{ error }}</p>
          <p v-else-if="!tools.length" class="muted" style="margin: 0">No editable tools available.</p>
        </div>

        <div class="modal-actions">
          <button class="primary" type="button" :disabled="confirmDisabled" @click="confirm">
            {{ saving ? 'Adding…' : confirmLabel }}
          </button>
          <button type="button" :disabled="saving" @click="close">Cancel</button>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { computed, Teleport } from 'vue';

type ToolOption = {
  id: number;
  name: string;
  type: string;
};

const props = withDefaults(
  defineProps<{
    open: boolean;
    title?: string;
    tools: ToolOption[];
    toolInstanceId: number;
    alias: string;
    loading?: boolean;
    saving?: boolean;
    error?: string | null;
    confirmLabel?: string;
  }>(),
  {
    title: 'Add tool',
    loading: false,
    saving: false,
    error: null,
    confirmLabel: 'Add',
  }
);

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'update:toolInstanceId', value: number): void;
  (e: 'update:alias', value: string): void;
  (e: 'confirm'): void;
}>();

const confirmDisabled = computed(
  () => props.saving || props.loading || !props.tools.length || !props.toolInstanceId || !props.alias.trim()
);

const close = () => {
  if (props.saving) return;
  emit('update:open', false);
};

const confirm = () => {
  if (confirmDisabled.value) return;
  emit('confirm');
};

const handleToolSelect = (event: Event) => {
  const target = event.target as HTMLSelectElement | null;
  emit('update:toolInstanceId', Number(target?.value || 0));
};

const handleAliasInput = (event: Event) => {
  const target = event.target as HTMLInputElement | null;
  emit('update:alias', target?.value || '');
};
</script>

<style scoped>
.tool-binding-picker {
  max-width: 520px;
}

.tool-binding-picker__note {
  margin: 0;
  font-size: 0.85rem;
}
</style>
