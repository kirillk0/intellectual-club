<template>
  <div class="branch-options" role="group" :aria-label="t('Branch options')">
    <div class="branch-options__row">
      <span class="branch-options__label">{{ t('Configuration') }}</span>
      <ChatConfigurationSelect
        class="branch-options__select"
        :model-value="configId"
        :disabled="disabled"
        :selectable-configs="selectableConfigs"
        :default-config="defaultConfig"
        :regular-selectable-configs="regularSelectableConfigs"
        :more-configs="moreConfigs"
        :selected-disabled-config="null"
        :config-label="configLabel"
        :show-edit-action="false"
        over-modal
        @update:model-value="emit('update:configId', $event)"
      />
    </div>
    <p v-if="configSwitchesChat" class="hint branch-options__hint">
      {{ t('This chat will switch to the selected configuration.') }}
    </p>

    <label class="settings-check branch-options__toggle">
      <input
        type="checkbox"
        :checked="startGeneration"
        :disabled="disabled"
        @change="emit('update:startGeneration', ($event.target as HTMLInputElement).checked)"
      />
      <span class="settings-check__body">
        <span class="settings-check__title">{{ t('Start generation') }}</span>
        <span v-if="!startGeneration" class="hint">
          {{
            newChat
              ? t('The new chat opens without a response, so you can adjust its settings first. Press Continue to generate it.')
              : t('The branch is created without a response. Press Continue to generate it.')
          }}
        </span>
      </span>
    </label>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import ChatConfigurationSelect from '@/features/chat/components/ChatConfigurationSelect.vue';
import { translate as t } from '@/i18n';
import type { LlmConfiguration } from '@/types/api';

type ConfigValue = number | '';

interface Props {
  configId: ConfigValue;
  startGeneration: boolean;
  // Branches into a new chat keep the source chat configuration untouched.
  newChat: boolean;
  // The configuration of the current chat, used to explain in-chat switches.
  currentConfigId: ConfigValue;
  disabled?: boolean;
  selectableConfigs: LlmConfiguration[];
  defaultConfig: LlmConfiguration | null;
  regularSelectableConfigs: LlmConfiguration[];
  moreConfigs: LlmConfiguration[];
  configLabel: (cfg: LlmConfiguration) => string;
}

const props = withDefaults(defineProps<Props>(), {
  disabled: false,
});

const emit = defineEmits<{
  (e: 'update:configId', value: ConfigValue): void;
  (e: 'update:startGeneration', value: boolean): void;
}>();

const configSwitchesChat = computed(
  () => !props.newChat && props.configId !== '' && props.configId !== props.currentConfigId
);
</script>

<style scoped>
.branch-options {
  display: grid;
  gap: 10px;
}

.branch-options__row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px 12px;
}

.branch-options__label {
  font-weight: 600;
  color: var(--color-text);
}

.branch-options__select {
  min-width: 0;
  max-width: 100%;
}

.branch-options__hint {
  margin: -4px 0 0;
}
</style>
