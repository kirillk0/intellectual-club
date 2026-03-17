<template>
  <div class="chat-header-toolbar">
    <div class="toolbar chat-toolbar fill">
      <RouterLink to="/" class="link" aria-label="Back to chats">←</RouterLink>
      <div class="header-actions toolbar-actions-right">
        <label class="flex">
          <span class="config-label">
            Config
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
          </span>
          <select
            :value="selectedConfig"
            @change="handleConfigChange"
            :disabled="configSyncStatus === 'pending'"
            :title="configSyncStatus === 'pending' ? 'Waiting for server confirmation' : undefined"
          >
            <option value="">No config</option>
            <option v-if="selectedDisabledConfig" :value="selectedDisabledConfig.id" disabled>
              {{ configLabel(selectedDisabledConfig) }} ({{ selectedDisabledConfigReasonLabel }})
            </option>
            <option v-for="cfg in selectableConfigs" :key="cfg.id" :value="cfg.id">
              {{ configLabel(cfg) }}
            </option>
          </select>
        </label>

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
            <button class="menu-item" type="button" @click="emit('duplicate-active-branch')" :disabled="duplicating">
              {{ duplicating ? 'Duplicating…' : 'Duplicate active branch' }}
            </button>
            <button class="menu-item" type="button" @click="emit('export-markdown')" :disabled="exporting">
              {{ exporting ? 'Exporting…' : 'Export Markdown' }}
            </button>
            <button class="menu-item" type="button" @click="emit('export-yaml')" :disabled="exporting">
              {{ exporting ? 'Exporting…' : 'Export YAML' }}
            </button>
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

import type { LlmConfiguration } from '@/types/api';

interface Props {
  selectedConfig: number | '';
  appliedConfig: number | '';
  selectableConfigs: LlmConfiguration[];
  selectedDisabledConfig: LlmConfiguration | null;
  selectedDisabledConfigReason: 'disabled' | 'incompatible' | null;
  configLabel: (cfg: LlmConfiguration) => string;
  editConfigLabel: string;
  configSyncStatus: 'synced' | 'pending' | 'error';
  configSyncError: string;
  menuOpen: boolean;
  menuStyle: Record<string, string>;
  currentBotId: number | null;
  currentBotName: string;
  chatNote: string;
  duplicating: boolean;
  exporting: boolean;
  deleting: boolean;
  showMissingToolsBanner: boolean;
  missingRequiredPerUserToolAliases: string[];
  setMenuRef: (el: Element | null) => void;
  setMenuAnchorRef: (el: Element | null) => void;
  setMenuButtonRef: (el: Element | null) => void;
}

const props = defineProps<Props>();

const selectedDisabledConfigReasonLabel = computed(() => {
  if (props.selectedDisabledConfigReason === 'incompatible') return 'incompatible';
  return 'disabled';
});

const emit = defineEmits<{
  (e: 'update:selectedConfig', value: number | ''): void;
  (e: 'change-config'): void;
  (e: 'toggle-menu'): void;
  (e: 'open-config-editor'): void;
  (e: 'open-bot-editor'): void;
  (e: 'open-bot-modal'): void;
  (e: 'open-note-modal'): void;
  (e: 'duplicate-active-branch'): void;
  (e: 'export-markdown'): void;
  (e: 'export-yaml'): void;
  (e: 'delete-chat'): void;
  (e: 'open-bot-tools'): void;
  (e: 'dismiss-missing-tools-banner'): void;
}>();

const handleConfigChange = (event: Event) => {
  const target = event.target as HTMLSelectElement;
  const value = target.value;
  emit('update:selectedConfig', value === '' ? '' : Number(value));
  emit('change-config');
};

const appliedConfigText = computed(() => {
  if (props.appliedConfig === '') return 'No config';
  const id = Number(props.appliedConfig);
  if (!Number.isFinite(id)) return 'No config';
  const hit =
    props.selectableConfigs.find((c) => c.id === id) ||
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

.config-label {
  display: inline-flex;
  align-items: center;
  gap: 8px;
}

.config-status {
  font-size: 0.85em;
  font-weight: 400;
}
</style>
