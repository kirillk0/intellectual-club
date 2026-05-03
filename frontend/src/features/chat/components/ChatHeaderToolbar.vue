<template>
  <div class="chat-header-toolbar">
    <div class="toolbar chat-toolbar fill">
      <div class="chat-toolbar__left">
        <RouterLink to="/" class="icon-button chat-toolbar__nav-button" aria-label="Back to chats" title="Back to chats">
          ←
        </RouterLink>
        <button
          class="icon-button chat-toolbar__nav-button"
          type="button"
          aria-label="New chat"
          title="New chat"
          @click="emit('open-new-chat')"
          :disabled="creatingChat"
        >
          {{ creatingChat ? '…' : '+' }}
        </button>
      </div>

      <div class="chat-toolbar__title-wrap">
        <div v-if="chatBaseTitle" class="chat-toolbar__title" :title="chatFullTitle">
          <span class="chat-toolbar__title-main">{{ chatBaseTitle }}</span>
          <span v-if="currentConfigLabel" class="chat-toolbar__title-config">({{ currentConfigLabel }})</span>
        </div>
      </div>

      <div class="header-actions toolbar-actions-right">
        <div class="flex config-control">
          <span
            v-if="configSyncStatus === 'pending'"
            class="config-status muted"
            :title="`Effective: ${appliedConfigText}`"
            aria-live="polite"
          >
            Saving…
          </span>
          <span
            v-else-if="configSyncStatus === 'error'"
            class="config-status error-text"
            :title="configSyncError || 'Failed to switch configuration'"
            aria-live="polite"
          >
            Not saved
          </span>
          <ChatConfigurationSelect
            :model-value="selectedConfig"
            :disabled="configSelectorDisabled"
            :title="configSelectorTitle"
            :selectable-configs="selectableConfigs"
            :default-config="defaultConfig"
            :regular-selectable-configs="regularSelectableConfigs"
            :more-configs="moreConfigs"
            :selected-disabled-config="selectedDisabledConfig"
            :config-label="configLabel"
            @update:model-value="emit('update:selectedConfig', $event)"
            @change="emit('change-config')"
          />
        </div>

        <div class="menu" :ref="setMenuAnchorRef">
          <button
            class="icon-button"
            type="button"
            :ref="setMenuButtonRef"
            @click.stop="emit('toggle-menu')"
            aria-label="More actions"
          >
            ⋯
          </button>
        </div>

        <Teleport to="body">
          <div class="dropdown floating-dropdown" v-if="menuOpen" :ref="setMenuRef" :style="menuStyle">
            <button class="menu-item" type="button" @click="emit('open-config-editor')" :disabled="!selectedConfig">
              {{ editConfigLabel }}
            </button>
            <div class="menu-divider" aria-hidden="true"></div>
            <div
              class="menu-item"
              style="text-align: left; padding: 8px 12px 10px; border-bottom: 1px solid #f0f0f0"
            >
              <div style="font-weight: 600; font-size: 0.95rem">Bot</div>
              <div style="display: flex; align-items: center; gap: 8px; margin-top: 4px; font-size: 0.93rem">
                <button
                  v-if="currentBotId"
                  type="button"
                  class="link"
                  @click="emit('open-bot-editor')"
                  :title="`Open bot editor: ${currentBotName}`"
                  style="
                    flex: 1;
                    min-width: 0;
                    white-space: nowrap;
                    overflow: hidden;
                    text-overflow: ellipsis;
                    padding: 0;
                    text-align: left;
                  "
                >
                  {{ currentBotName }}
                </button>
                <span
                  v-else
                  style="flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis"
                >
                  {{ currentBotName || 'No bot' }}
                </span>
                <button type="button" class="link" @click="emit('open-bot-modal')" style="padding: 0">
                  change
                </button>
              </div>
            </div>
            <div
              class="menu-item"
              style="text-align: left; padding: 8px 12px 10px; border-bottom: 1px solid #f0f0f0"
            >
              <div style="font-weight: 600; font-size: 0.95rem">Note</div>
              <div style="display: flex; align-items: center; gap: 8px; margin-top: 4px; font-size: 0.93rem">
                <span
                  style="
                    flex: 1;
                    min-width: 0;
                    white-space: nowrap;
                    overflow: hidden;
                    text-overflow: ellipsis;
                  "
                  :title="chatNote || 'No note'"
                >
                  {{ chatNote || 'No note' }}
                </span>
                <button type="button" class="link" @click="emit('open-note-modal')" style="padding: 0">edit</button>
              </div>
            </div>
            <button class="menu-item danger" type="button" @click="emit('delete-chat')" :disabled="deleting">
              {{ deleting ? 'Deleting…' : 'Delete chat' }}
            </button>
          </div>
        </Teleport>
      </div>
    </div>

    <div
      v-if="showMissingToolsBanner"
      class="card flex"
      style="padding: 10px; justify-content: space-between; align-items: center; gap: 12px"
    >
      <div style="min-width: 0">
        <div style="font-weight: 600">Missing required tools</div>
        <div class="muted" style="font-size: 0.85rem">
          This bot expects per-user tools for the following aliases:
          <code>{{ missingRequiredPerUserToolAliases.join(', ') }}</code
          >.
        </div>
      </div>
      <div class="flex" style="gap: 8px; align-items: center">
        <button type="button" class="primary" @click="emit('open-bot-tools')">Configure tools</button>
        <button type="button" @click="emit('dismiss-missing-tools-banner')">Dismiss</button>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import ChatConfigurationSelect from './ChatConfigurationSelect.vue';
import type { LlmConfiguration } from '@/types/api';

interface Props {
  selectedConfig: number | '';
  appliedConfig: number | '';
  selectableConfigs: LlmConfiguration[];
  defaultConfig: LlmConfiguration | null;
  regularSelectableConfigs: LlmConfiguration[];
  moreConfigs: LlmConfiguration[];
  selectedDisabledConfig: LlmConfiguration | null;
  selectedDisabledConfigReason: 'disabled' | 'incompatible' | null;
  configLabel: (cfg: LlmConfiguration) => string;
  editConfigLabel: string;
  configSyncStatus: 'synced' | 'pending' | 'error';
  configSyncError: string;
  isGenerating: boolean;
  menuOpen: boolean;
  menuStyle: Record<string, string>;
  currentBotId: number | null;
  currentBotName: string;
  chatBaseTitle: string;
  chatFullTitle: string;
  currentConfigLabel: string;
  chatNote: string;
  creatingChat: boolean;
  deleting: boolean;
  showMissingToolsBanner: boolean;
  missingRequiredPerUserToolAliases: string[];
  setMenuRef: (el: Element | null) => void;
  setMenuAnchorRef: (el: Element | null) => void;
  setMenuButtonRef: (el: Element | null) => void;
}

const props = withDefaults(defineProps<Props>(), {
  selectableConfigs: () => [],
  defaultConfig: null,
  regularSelectableConfigs: () => [],
  moreConfigs: () => [],
  selectedDisabledConfig: null,
  selectedDisabledConfigReason: null,
});

const configSelectorDisabled = computed(() => props.configSyncStatus === 'pending' || props.isGenerating);

const configSelectorTitle = computed(() => {
  if (props.isGenerating) return 'Cannot change configuration while generating a response';
  if (props.configSyncStatus === 'pending') return 'Waiting for server confirmation';
  return undefined;
});

const emit = defineEmits<{
  (e: 'update:selectedConfig', value: number | ''): void;
  (e: 'change-config'): void;
  (e: 'toggle-menu'): void;
  (e: 'open-new-chat'): void;
  (e: 'open-config-editor'): void;
  (e: 'open-bot-editor'): void;
  (e: 'open-bot-modal'): void;
  (e: 'open-note-modal'): void;
  (e: 'delete-chat'): void;
  (e: 'open-bot-tools'): void;
  (e: 'dismiss-missing-tools-banner'): void;
}>();

const appliedConfigText = computed(() => {
  if (props.appliedConfig === '') return 'No config';
  const id = Number(props.appliedConfig);
  if (!Number.isFinite(id)) return 'No config';
  const hit =
    props.selectableConfigs.find((c) => c.id === id) ||
    props.moreConfigs.find((c) => c.id === id) ||
    (props.selectedDisabledConfig?.id === id ? props.selectedDisabledConfig : null);
  return hit ? props.configLabel(hit) : `Config #${id}`;
});

const setMenuRef = (el: Element | null) => {
  props.setMenuRef(el);
};

const setMenuAnchorRef = (el: Element | null) => {
  props.setMenuAnchorRef(el);
};

const setMenuButtonRef = (el: Element | null) => {
  props.setMenuButtonRef(el);
};
</script>

<style scoped>
.chat-header-toolbar {
  width: 100%;
  min-width: 0;
}

.chat-toolbar {
  justify-content: space-between;
  min-width: 0;
}

.config-status {
  font-size: 0.85em;
  font-weight: 400;
}

.config-control {
  align-items: center;
}

.chat-toolbar__left {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  flex: 0 0 auto;
}

.chat-toolbar__nav-button {
  color: #111827;
  text-decoration: none;
  font-size: 18px;
}

.chat-toolbar__nav-button:disabled {
  opacity: 0.6;
  cursor: default;
}

.chat-toolbar__title-wrap {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  justify-content: center;
  overflow: hidden;
}

.chat-toolbar__title {
  min-width: 0;
  max-width: 100%;
  display: inline-flex;
  align-items: baseline;
  justify-content: center;
  gap: 6px;
  overflow: hidden;
}

.chat-toolbar__title-main {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-weight: 600;
}

.chat-toolbar__title-config {
  flex: 0 0 auto;
  color: #6b7280;
  font-size: 0.85rem;
  white-space: nowrap;
}

@media (max-width: 860px) {
  .chat-toolbar__title {
    display: none;
  }
}
</style>
