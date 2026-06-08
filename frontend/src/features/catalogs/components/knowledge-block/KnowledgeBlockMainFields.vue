<template>
  <div class="card stack">
    <div v-if="formErrors.length" class="error-text">{{ formErrors.join(' ') }}</div>

    <label :class="{ 'field-error': nameError }">
      Name
      <input :value="name" class="full" @input="updateName" />
      <div v-if="nameError" class="error-text">{{ nameError }}</div>
    </label>

    <label :class="{ 'field-error': versionError }">
      Version
      <input :value="version" class="full" placeholder="Optional" @input="updateVersion" />
      <div v-if="versionError" class="error-text">{{ versionError }}</div>
    </label>
  </div>
</template>

<script setup lang="ts">
defineProps<{
  name: string;
  version: string;
  formErrors: string[];
  nameError: string | null;
  versionError: string | null;
}>();

const emit = defineEmits<{
  (e: 'update:name', value: string): void;
  (e: 'update:version', value: string): void;
  (e: 'clear-field', field: 'name' | 'version'): void;
}>();

function updateName(event: Event) {
  const target = event.target as HTMLInputElement | null;
  emit('update:name', target?.value ?? '');
  emit('clear-field', 'name');
}

function updateVersion(event: Event) {
  const target = event.target as HTMLInputElement | null;
  emit('update:version', target?.value ?? '');
  emit('clear-field', 'version');
}
</script>

