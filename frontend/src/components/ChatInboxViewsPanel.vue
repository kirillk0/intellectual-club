<template>
  <section class="card stack chat-inbox-views-panel">
    <div class="chat-inbox-views-panel__header">
      <strong>{{ t('Chats') }}</strong>
      <slot name="header-extra"></slot>
    </div>

    <div class="chat-inbox-views" role="group" :aria-label="t('Chat list view')">
      <button
        v-for="view in VIEWS"
        :key="view.value"
        type="button"
        class="chat-inbox-views__option"
        :class="{ active: modelValue === view.value }"
        :aria-pressed="modelValue === view.value"
        @click="emit('update:modelValue', view.value)"
      >
        <SvgIcon :name="view.icon" size="16" class="chat-inbox-views__icon" />
        <span class="chat-inbox-views__label">{{ t(view.label) }}</span>
      </button>
    </div>
  </section>
</template>

<script setup lang="ts">
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { translate as t } from '@/i18n';

export type ChatInboxView = 'inbox' | 'archive';

const VIEWS: { value: ChatInboxView; label: string; icon: string }[] = [
  { value: 'inbox', label: 'Inbox', icon: 'inbox' },
  { value: 'archive', label: 'Archive', icon: 'archive' },
];

defineProps<{
  modelValue: ChatInboxView;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: ChatInboxView];
}>();
</script>

<style scoped>
.chat-inbox-views-panel {
  gap: 10px;
}

.chat-inbox-views-panel__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.chat-inbox-views {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.chat-inbox-views__option {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  min-height: 36px;
  padding: 7px 8px;
  border-color: transparent;
  background: transparent;
  text-align: left;
}

.chat-inbox-views__option:hover,
.chat-inbox-views__option:focus-visible,
.chat-inbox-views__option.active {
  background: var(--color-surface-muted);
  border-color: var(--color-border-strong);
}

.chat-inbox-views__option.active {
  color: var(--color-primary);
}

.chat-inbox-views__icon {
  color: var(--color-text-muted);
}

.chat-inbox-views__option.active .chat-inbox-views__icon {
  color: inherit;
}

.chat-inbox-views__label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
</style>
