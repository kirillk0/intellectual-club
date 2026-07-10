<template>
  <section class="card remote-update-notice" role="status">
    <div class="remote-update-notice__copy">
      <strong>This record changed on the server.</strong>
      <span>Your unsaved changes were kept.</span>
    </div>
    <div class="remote-update-notice__actions">
      <button type="button" @click="emit('keep-editing')">Keep editing</button>
      <button class="primary" type="button" @click="emit('reload')">Reload server version</button>
    </div>
  </section>
</template>

<script setup lang="ts">
const emit = defineEmits<{
  (event: 'reload'): void;
  (event: 'keep-editing'): void;
}>();
</script>

<style scoped>
.remote-update-notice {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  border-color: var(--color-warning-border);
  background: var(--color-warning-bg);
}

.remote-update-notice__copy {
  display: flex;
  flex-direction: column;
  gap: 3px;
}

.remote-update-notice__actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

@media (max-width: 640px) {
  .remote-update-notice {
    align-items: stretch;
    flex-direction: column;
  }
}
</style>
