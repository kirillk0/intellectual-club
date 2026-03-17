<template>
  <Teleport to="body">
    <div v-if="open" class="modal-backdrop" @click.self="emitClose">
      <div class="modal" role="dialog" aria-modal="true" style="max-width: 520px">
        <h3 style="margin: 0 0 12px">{{ title }}</h3>
        <p class="muted" style="margin-top: 0">
          Select groups that should have access. Group members will see this item read-only.
        </p>

        <div v-if="loading" class="muted">Loading…</div>
        <div v-else class="stack" style="gap: 10px; max-height: 55vh; overflow: auto">
          <p v-if="!groups.length" class="muted">You are not a member of any groups.</p>
          <label v-for="group in groups" :key="group.id" class="flex" style="gap: 10px; align-items: center">
            <input v-model="selected" type="checkbox" :value="group.id" :disabled="saving" />
            <span>{{ group.name }}</span>
          </label>
        </div>

        <div class="modal-actions">
          <button class="primary" type="button" :disabled="saving || loading" @click="emitSave">
            {{ saving ? 'Saving…' : 'Save' }}
          </button>
          <button type="button" :disabled="saving" @click="emitClose">Cancel</button>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { ref, watch } from 'vue';
import type { Group } from '@/types/api';

const props = withDefaults(
  defineProps<{
    open: boolean;
    title?: string;
    groups: Group[];
    selectedGroupIds: number[];
    loading?: boolean;
    saving?: boolean;
  }>(),
  {
    title: 'Share',
    loading: false,
    saving: false,
  }
);

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'save', groupIds: number[]): void;
}>();

const selected = ref<number[]>([]);

watch(
  () => props.open,
  (isOpen) => {
    if (isOpen) selected.value = [...(props.selectedGroupIds || [])];
  }
);

watch(
  () => props.selectedGroupIds,
  (ids) => {
    if (props.open) selected.value = [...(ids || [])];
  }
);

const emitClose = () => emit('update:open', false);
const emitSave = () => emit('save', [...selected.value]);
</script>
