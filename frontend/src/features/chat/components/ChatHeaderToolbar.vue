<template>
  <div class="chat-header-toolbar">
    <div class="toolbar chat-toolbar fill">
      <div class="chat-toolbar__title-wrap">
        <div v-if="chatBaseTitle" class="chat-toolbar__title" :title="chatFullTitle">
          <span class="chat-toolbar__title-main">{{ chatBaseTitle }}</span>
          <button
            v-if="canEdit"
            class="icon-button chat-toolbar__title-edit"
            type="button"
            :aria-label="t('Edit chat note')"
            :title="t('Edit chat note')"
            @click="emit('open-note-modal')"
          >
            <SvgIcon name="edit" size="14" />
          </button>
        </div>
      </div>

      <div class="header-actions toolbar-actions-right chat-toolbar__actions">
        <div class="flex config-control">
          <span
            v-if="configSyncStatus === 'pending'"
            class="config-status muted"
            :title="t('Effective: {value}', { value: appliedConfigText })"
            aria-live="polite"
          >
            {{ t('Saving…') }}
          </span>
          <span
            v-else-if="configSyncStatus === 'error'"
            class="config-status error-text"
            :title="configSyncError ? t(configSyncError) : t('Failed to switch configuration')"
            aria-live="polite"
          >
            {{ t('Not saved') }}
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

        <button
          class="icon-button toolbar-create-button chat-toolbar__icon-button"
          type="button"
          :aria-label="t(creatingChat ? 'Creating…' : 'New chat')"
          :title="t(creatingChat ? 'Creating…' : 'New chat')"
          @click="emit('open-new-chat')"
          :disabled="creatingChat"
        >
          <SvgIcon name="plus" size="16" />
        </button>

        <div class="menu" :ref="setMenuAnchorRef">
          <button
            class="icon-button chat-toolbar__icon-button"
            type="button"
            :ref="setMenuButtonRef"
            @click.stop="emit('toggle-menu')"
            :aria-label="t('More actions')"
            :title="t('More actions')"
          >
            <SvgIcon name="more-horizontal" size="16" />
          </button>
        </div>

        <RouterLink :to="backTo" class="icon-button chat-toolbar__icon-button" :aria-label="t('Close')" :title="t('Close')">
          <SvgIcon name="x" size="16" />
        </RouterLink>

        <Teleport to="body">
          <div class="dropdown floating-dropdown" v-if="menuOpen" :ref="setMenuRef" :style="menuStyle">
            <button
              class="menu-item chat-menu-item"
              type="button"
              @click="emit('open-config-editor')"
              :disabled="!selectedConfig"
            >
              <span class="chat-menu-item__icon" aria-hidden="true">
                <SvgIcon name="sliders" size="16" />
              </span>
              <span class="chat-menu-item__label">{{ t(editConfigLabel) }}</span>
            </button>
            <button v-if="canEdit" class="menu-item chat-menu-item" type="button" @click="emit('open-share')">
              <span class="chat-menu-item__icon" aria-hidden="true">
                <SvgIcon name="share-outgoing" size="16" />
              </span>
              <span class="chat-menu-item__label">{{ t('Share…') }}</span>
            </button>
            <button
              v-if="canEdit"
              class="menu-item chat-menu-item"
              type="button"
              @click="emit('handoff')"
              :disabled="handoffDisabled"
              :title="handoffDisabled ? handoffDisabledTitle : undefined"
            >
              <span class="chat-menu-item__icon" aria-hidden="true">
                <SvgIcon name="branch" size="16" />
              </span>
              <span class="chat-menu-item__label">{{ t(handoffPending ? 'Handing off…' : 'Handoff') }}</span>
            </button>
            <div class="menu-divider" aria-hidden="true"></div>
            <div class="menu-item chat-menu-section">
              <div class="chat-menu-section__heading">
                <SvgIcon name="bot" size="16" />
                <span>{{ t('Bot') }}</span>
              </div>
              <div class="chat-menu-section__row">
                <button
                  v-if="currentBotId"
                  type="button"
                  class="link chat-menu-link"
                  @click="emit('open-bot-editor')"
                  :title="t('Open bot editor: {value}', { value: currentBotName })"
                >
                  <span>{{ currentBotName }}</span>
                </button>
                <span v-else class="chat-menu-value">
                  {{ currentBotName || t('No bot') }}
                </span>
                <button v-if="canEdit" type="button" class="link chat-menu-inline-action" @click="emit('open-bot-modal')">
                  <span>{{ t('change') }}</span>
                </button>
              </div>
            </div>
            <div class="menu-item chat-menu-section">
              <div class="chat-menu-section__heading">
                <SvgIcon name="document" size="16" />
                <span>{{ t('Note') }}</span>
              </div>
              <div class="chat-menu-section__row">
                <span class="chat-menu-value" :title="chatNote || t('No note')">
                  {{ chatNote || t('No note') }}
                </span>
                <button v-if="canEdit" type="button" class="link chat-menu-inline-action" @click="emit('open-note-modal')">
                  <span>{{ t('edit') }}</span>
                </button>
              </div>
            </div>
            <button
              v-if="canEdit"
              class="menu-item chat-menu-item danger"
              type="button"
              @click="emit('delete-chat')"
              :disabled="deleting"
            >
              <span class="chat-menu-item__icon" aria-hidden="true">
                <SvgIcon name="delete" size="16" />
              </span>
              <span class="chat-menu-item__label">{{ t(deleting ? 'Deleting…' : 'Delete chat') }}</span>
            </button>
          </div>
        </Teleport>
      </div>
    </div>

    <div
      v-if="canEdit && showMissingToolsBanner"
      class="card flex"
      style="padding: 10px; justify-content: space-between; align-items: center; gap: 12px"
    >
      <div style="min-width: 0">
        <div style="font-weight: 600">{{ t('Missing required tools') }}</div>
        <div class="muted" style="font-size: 0.85rem">
          {{ t('This bot expects per-user tools for the following aliases:') }}
          <code>{{ missingRequiredPerUserToolAliases.join(', ') }}</code
          >.
        </div>
      </div>
      <div class="flex" style="gap: 8px; align-items: center">
        <button type="button" class="primary" @click="emit('open-bot-tools')">{{ t('Configure tools') }}</button>
        <button type="button" @click="emit('dismiss-missing-tools-banner')">{{ t('Dismiss') }}</button>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, type ComponentPublicInstance } from 'vue';

import SvgIcon from '@/components/icons/SvgIcon.vue';
import { translate } from '@/i18n';
import ChatConfigurationSelect from './ChatConfigurationSelect.vue';
import type { LlmConfiguration } from '@/types/api';

interface Props {
  backTo?: string;
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
  chatNote: string;
  creatingChat: boolean;
  deleting: boolean;
  canEdit: boolean;
  handoffPending: boolean;
  handoffDisabled: boolean;
  showMissingToolsBanner: boolean;
  missingRequiredPerUserToolAliases: string[];
  setMenuRef: (el: TemplateRefValue) => void;
  setMenuAnchorRef: (el: TemplateRefValue) => void;
  setMenuButtonRef: (el: TemplateRefValue) => void;
}

type TemplateRefValue = Element | ComponentPublicInstance | null;
const t = translate;

const props = withDefaults(defineProps<Props>(), {
  backTo: '/chats',
  selectableConfigs: () => [],
  defaultConfig: null,
  regularSelectableConfigs: () => [],
  moreConfigs: () => [],
  selectedDisabledConfig: null,
  selectedDisabledConfigReason: null,
});

const configSelectorDisabled = computed(() => !props.canEdit || props.configSyncStatus === 'pending' || props.isGenerating);

const configSelectorTitle = computed(() => {
  if (!props.canEdit) return t('Shared chats are read-only');
  if (props.isGenerating) return t('Cannot change configuration while generating a response');
  if (props.configSyncStatus === 'pending') return t('Waiting for server confirmation');
  return undefined;
});

const handoffDisabledTitle = computed(() => {
  if (props.isGenerating) return t('Cannot handoff while generating or syncing configuration');
  if (props.configSyncStatus === 'pending') return t('Cannot handoff while generating or syncing configuration');
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
  (e: 'open-share'): void;
  (e: 'handoff'): void;
  (e: 'delete-chat'): void;
  (e: 'open-bot-tools'): void;
  (e: 'dismiss-missing-tools-banner'): void;
}>();

const appliedConfigText = computed(() => {
  if (props.appliedConfig === '') return t('No config');
  const id = Number(props.appliedConfig);
  if (!Number.isFinite(id)) return t('No config');
  const hit =
    props.selectableConfigs.find((c) => c.id === id) ||
    props.moreConfigs.find((c) => c.id === id) ||
    (props.selectedDisabledConfig?.id === id ? props.selectedDisabledConfig : null);
  return hit ? props.configLabel(hit) : `Config #${id}`;
});

const setMenuRef = (el: TemplateRefValue) => {
  props.setMenuRef(el);
};

const setMenuAnchorRef = (el: TemplateRefValue) => {
  props.setMenuAnchorRef(el);
};

const setMenuButtonRef = (el: TemplateRefValue) => {
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

.chat-toolbar__title-wrap {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  justify-content: flex-start;
  overflow: hidden;
}

.chat-toolbar__title {
  min-width: 0;
  max-width: 100%;
  display: inline-flex;
  align-items: center;
  justify-content: flex-start;
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

.chat-toolbar__title-edit {
  flex: 0 0 auto;
  width: 24px;
  height: 24px;
  color: var(--color-text-muted);
  font-size: 14px;
}

.chat-toolbar__actions {
  flex: 0 0 auto;
  min-width: 0;
  gap: 6px;
}

.chat-toolbar__icon-button {
  color: var(--color-text);
  text-decoration: none;
}

.chat-toolbar__icon-button .svg-icon,
.toolbar-create-button .svg-icon {
  stroke-width: 1.35;
}

.chat-menu-item {
  display: flex;
  align-items: center;
  gap: 10px;
}

.chat-menu-item__icon {
  width: 18px;
  display: inline-flex;
  justify-content: center;
  color: var(--color-text-muted);
}

.chat-menu-item__label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.chat-menu-section {
  text-align: left;
  padding: 8px 12px 10px;
  border-bottom: 1px solid var(--color-border);
}

.chat-menu-section__heading {
  display: flex;
  align-items: center;
  gap: 8px;
  color: var(--color-text);
  font-weight: 600;
  font-size: 0.95rem;
}

.chat-menu-section__heading .svg-icon,
.chat-menu-item .svg-icon {
  stroke-width: 1.35;
}

.chat-menu-section__row {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: 4px;
  font-size: 0.93rem;
}

.chat-menu-link,
.chat-menu-inline-action,
.chat-menu-value {
  display: inline-flex;
  align-items: center;
  min-width: 0;
}

.chat-menu-link {
  flex: 1;
  padding: 0;
  text-align: left;
}

.chat-menu-link span,
.chat-menu-value {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.chat-menu-value {
  flex: 1;
}

.chat-menu-inline-action {
  flex: 0 0 auto;
  padding: 0;
}

@media (max-width: 720px) {
  .chat-toolbar {
    gap: 6px;
  }

  .chat-toolbar__actions {
    gap: 4px;
  }
}
</style>
