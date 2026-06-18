<template>
  <div
    ref="configMenuRef"
    class="config-select"
    :class="{ 'config-select--disabled': disabled, 'config-select--open': configMenuOpen }"
    @click.stop
    @keydown.esc="closeConfigMenu"
  >
    <button
      ref="configTriggerRef"
      type="button"
      class="config-select__trigger"
      :disabled="disabled"
      :aria-expanded="configMenuOpen ? 'true' : 'false'"
      aria-haspopup="menu"
      :title="title || currentConfigText"
      @click="toggleConfigMenu"
    >
      <span class="config-select__trigger-label">{{ currentConfigText }}</span>
    </button>

    <Teleport to="body">
      <div
        v-if="configMenuOpen"
        ref="configDropdownRef"
        class="config-select__menu config-select__menu--floating"
        role="menu"
        aria-label="Configuration"
        :style="configMenuStyle"
        @click.stop
        @keydown.esc="closeConfigMenu"
      >
        <button
          v-if="defaultConfig"
          class="config-select__item"
          type="button"
          role="menuitem"
          :title="configLabel(defaultConfig)"
          @click="selectConfig(defaultConfig.id)"
        >
          {{ configLabel(defaultConfig) }}
        </button>
        <div v-if="defaultConfig && (regularSelectableConfigs.length || moreMenuItems.length)" class="menu-divider"></div>
        <button
          v-for="cfg in regularSelectableConfigs"
          :key="cfg.id"
          class="config-select__item"
          type="button"
          role="menuitem"
          :title="configLabel(cfg)"
          @click="selectConfig(cfg.id)"
        >
          {{ configLabel(cfg) }}
        </button>
        <div
          v-if="moreMenuItems.length"
          class="config-select__submenu"
          @mouseenter="scheduleOpenMoreConfigMenu"
          @pointerenter="scheduleOpenMoreConfigMenu"
          @mouseleave="scheduleCloseMoreConfigMenu"
          @pointerleave="scheduleCloseMoreConfigMenu"
        >
          <button
            ref="moreTriggerRef"
            class="config-select__item config-select__submenu-trigger"
            type="button"
            role="menuitem"
            aria-haspopup="menu"
            :aria-expanded="moreMenuOpen ? 'true' : 'false'"
            @focus="openMoreConfigMenu"
            @click.stop="openMoreConfigMenu"
          >
            <span class="config-select__submenu-label">More</span>
            <span aria-hidden="true">‹</span>
          </button>
        </div>
      </div>
    </Teleport>

    <Teleport to="body">
      <div
        v-if="configMenuOpen && moreMenuOpen"
        ref="moreDropdownRef"
        class="config-select__submenu-menu config-select__submenu-menu--floating"
        role="menu"
        aria-label="More configurations"
        :style="moreMenuStyle"
        @click.stop
        @mouseenter="cancelMoreConfigMenuClose"
        @pointerenter="cancelMoreConfigMenuClose"
        @mouseleave="scheduleCloseMoreConfigMenu"
        @pointerleave="scheduleCloseMoreConfigMenu"
        @keydown.esc="closeConfigMenu"
      >
        <button
          v-for="item in moreMenuItems"
          :key="item.key"
          class="config-select__item"
          type="button"
          role="menuitem"
          :title="item.title"
          @click="selectConfig(item.value)"
        >
          {{ item.label }}
        </button>
      </div>
    </Teleport>
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref } from 'vue';

import type { LlmConfiguration } from '@/types/api';

type ConfigValue = number | '';

interface MoreMenuItem {
  key: string;
  label: string;
  title: string;
  value: ConfigValue;
}

interface Props {
  modelValue: ConfigValue;
  disabled: boolean;
  title?: string;
  selectableConfigs: LlmConfiguration[];
  defaultConfig: LlmConfiguration | null;
  regularSelectableConfigs: LlmConfiguration[];
  moreConfigs: LlmConfiguration[];
  selectedDisabledConfig: LlmConfiguration | null;
  configLabel: (cfg: LlmConfiguration) => string;
}

const props = withDefaults(defineProps<Props>(), {
  title: undefined,
  selectableConfigs: () => [],
  defaultConfig: null,
  regularSelectableConfigs: () => [],
  moreConfigs: () => [],
  selectedDisabledConfig: null,
});

const emit = defineEmits<{
  (e: 'update:modelValue', value: ConfigValue): void;
  (e: 'change'): void;
}>();

const configMenuRef = ref<HTMLElement | null>(null);
const configTriggerRef = ref<HTMLElement | null>(null);
const configDropdownRef = ref<HTMLElement | null>(null);
const moreTriggerRef = ref<HTMLElement | null>(null);
const moreDropdownRef = ref<HTMLElement | null>(null);
const configMenuOpen = ref(false);
const moreMenuOpen = ref(false);
const configMenuStyle = ref<Record<string, string>>({});
const moreMenuStyle = ref<Record<string, string>>({});
let moreMenuOpenTimer: number | null = null;
let moreMenuCloseTimer: number | null = null;

const moreConfigReason = (config: LlmConfiguration) => {
  if (config.enabled === false) return ' (disabled)';
  return ' (incompatible)';
};

const moreMenuItems = computed<MoreMenuItem[]>(() => [
  {
    key: 'no-config',
    label: 'No config',
    title: 'No config',
    value: '',
  },
  ...props.moreConfigs.map((config) => {
    const label = `${props.configLabel(config)}${moreConfigReason(config)}`;
    return {
      key: String(config.id),
      label,
      title: label,
      value: config.id,
    };
  }),
]);

const currentConfigText = computed(() => {
  if (props.modelValue === '') return 'No config';
  const id = Number(props.modelValue);
  if (!Number.isFinite(id)) return 'No config';
  const hit =
    props.selectableConfigs.find((c) => c.id === id) ||
    props.moreConfigs.find((c) => c.id === id) ||
    (props.selectedDisabledConfig?.id === id ? props.selectedDisabledConfig : null);
  return hit ? props.configLabel(hit) : `Config #${id}`;
});

const cancelMoreConfigMenuOpen = () => {
  if (moreMenuOpenTimer === null) return;
  window.clearTimeout(moreMenuOpenTimer);
  moreMenuOpenTimer = null;
};

const cancelMoreConfigMenuClose = () => {
  if (moreMenuCloseTimer === null) return;
  window.clearTimeout(moreMenuCloseTimer);
  moreMenuCloseTimer = null;
};

const closeConfigMenu = () => {
  cancelMoreConfigMenuOpen();
  cancelMoreConfigMenuClose();
  configMenuOpen.value = false;
  moreMenuOpen.value = false;
};

const updateConfigMenuPosition = () => {
  if (!configMenuOpen.value) return;
  const trigger = configTriggerRef.value;
  if (!trigger) return;

  const rect = trigger.getBoundingClientRect();
  const viewportPadding = 8;
  const menuGap = 6;
  const preferredWidth = 260;
  const maxWidth = Math.max(220, window.innerWidth - viewportPadding * 2);
  const width = Math.min(preferredWidth, maxWidth);
  const maxLeft = Math.max(viewportPadding, window.innerWidth - width - viewportPadding);
  const left = Math.min(Math.max(viewportPadding, rect.right - width), maxLeft);
  const spaceBelow = Math.max(120, window.innerHeight - rect.bottom - menuGap - viewportPadding);
  const spaceAbove = Math.max(120, rect.top - menuGap - viewportPadding);
  const menuHeight = configDropdownRef.value?.scrollHeight ?? 0;
  const openAbove = menuHeight > spaceBelow && spaceAbove > spaceBelow;
  const availableHeight = openAbove ? spaceAbove : spaceBelow;
  const top = openAbove
    ? Math.max(viewportPadding, rect.top - menuGap - Math.min(menuHeight, availableHeight))
    : Math.min(rect.bottom + menuGap, window.innerHeight - viewportPadding - availableHeight);

  configMenuStyle.value = {
    position: 'fixed',
    top: `${top}px`,
    left: `${left}px`,
    width: `${width}px`,
    maxWidth: `${maxWidth}px`,
    maxHeight: `${availableHeight}px`,
    zIndex: '2200',
  };
};

const updateMoreMenuPosition = () => {
  if (!configMenuOpen.value || !moreMenuOpen.value) return;
  const trigger = moreTriggerRef.value;
  if (!trigger) return;

  const rect = trigger.getBoundingClientRect();
  const viewportPadding = 8;
  const menuGap = 4;
  const preferredWidth = 380;
  const maxWidth = Math.max(220, window.innerWidth - viewportPadding * 2);
  const width = Math.min(preferredWidth, maxWidth);
  const maxHeight = Math.max(120, window.innerHeight - viewportPadding * 2);
  const menuHeight = Math.min(moreDropdownRef.value?.scrollHeight ?? maxHeight, maxHeight);
  const leftSide = rect.left - menuGap - width;
  const rightSide = rect.right + menuGap;
  const left =
    leftSide >= viewportPadding
      ? leftSide
      : Math.min(Math.max(viewportPadding, rightSide), window.innerWidth - viewportPadding - width);
  const top = Math.min(Math.max(viewportPadding, rect.bottom - menuHeight), window.innerHeight - viewportPadding - menuHeight);

  moreMenuStyle.value = {
    position: 'fixed',
    top: `${top}px`,
    left: `${left}px`,
    width: `${width}px`,
    maxWidth: `${maxWidth}px`,
    maxHeight: `${maxHeight}px`,
    zIndex: '2201',
  };
};

const openConfigMenu = async () => {
  if (props.disabled) return;
  configMenuOpen.value = true;
  await nextTick();
  updateConfigMenuPosition();
};

const toggleConfigMenu = async () => {
  if (props.disabled) return;
  if (configMenuOpen.value) {
    closeConfigMenu();
    return;
  }
  await openConfigMenu();
};

const handleDocumentClick = (event: MouseEvent) => {
  const target = event.target;
  if (!(target instanceof Node)) return;
  if (configMenuRef.value?.contains(target)) return;
  if (configDropdownRef.value?.contains(target)) return;
  if (moreDropdownRef.value?.contains(target)) return;
  closeConfigMenu();
};

const handleMenuReposition = () => {
  updateConfigMenuPosition();
  updateMoreMenuPosition();
};

const openMoreConfigMenu = async () => {
  if (!configMenuOpen.value || !moreMenuItems.value.length) return;
  cancelMoreConfigMenuOpen();
  cancelMoreConfigMenuClose();
  moreMenuOpen.value = true;
  await nextTick();
  updateMoreMenuPosition();
};

const scheduleOpenMoreConfigMenu = () => {
  if (!configMenuOpen.value || !moreMenuItems.value.length) return;
  cancelMoreConfigMenuClose();
  if (moreMenuOpen.value) {
    updateMoreMenuPosition();
    return;
  }
  cancelMoreConfigMenuOpen();
  moreMenuOpenTimer = window.setTimeout(() => {
    void openMoreConfigMenu();
  }, 180);
};

const scheduleCloseMoreConfigMenu = () => {
  cancelMoreConfigMenuOpen();
  cancelMoreConfigMenuClose();
  moreMenuCloseTimer = window.setTimeout(() => {
    moreMenuOpen.value = false;
    moreMenuCloseTimer = null;
  }, 120);
};

const selectConfig = (value: ConfigValue) => {
  if (props.disabled) return;
  closeConfigMenu();
  if (props.modelValue === value) return;
  emit('update:modelValue', value);
  emit('change');
};

onMounted(() => {
  document.addEventListener('click', handleDocumentClick);
  window.addEventListener('resize', handleMenuReposition);
  window.addEventListener('scroll', handleMenuReposition, true);
});

onBeforeUnmount(() => {
  closeConfigMenu();
  document.removeEventListener('click', handleDocumentClick);
  window.removeEventListener('resize', handleMenuReposition);
  window.removeEventListener('scroll', handleMenuReposition, true);
});
</script>

<style scoped>
.config-select {
  position: relative;
  min-width: 150px;
  max-width: min(220px, 56vw);
}

.config-select__trigger {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  width: 100%;
  min-height: 34px;
  padding: 6px 30px 6px 10px;
  border: 1px solid var(--color-border-strong);
  border-radius: 6px;
  background: var(--color-surface);
  color: var(--color-text);
  cursor: pointer;
  position: relative;
}

.config-select__trigger::after {
  content: '▾';
  position: absolute;
  right: 10px;
  top: 50%;
  transform: translateY(-50%);
  color: var(--color-text-muted);
  font-size: 0.8rem;
}

.config-select--open .config-select__trigger::after {
  content: '▴';
}

.config-select__trigger-label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.config-select--disabled .config-select__trigger {
  opacity: 0.6;
  cursor: default;
}

.config-select__menu,
.config-select__submenu-menu {
  min-width: 220px;
  max-width: min(320px, 82vw);
  border: 1px solid var(--color-border);
  border-radius: 8px;
  background: var(--color-surface);
  box-shadow: var(--shadow-menu);
  padding: 6px 0;
  z-index: 2200;
}

.config-select__menu--floating {
  position: fixed;
  overflow-y: auto;
  overscroll-behavior: contain;
}

.config-select__item {
  width: 100%;
  display: block;
  min-width: 0;
  border: none;
  background: transparent;
  color: var(--color-text);
  text-align: left;
  padding: 9px 12px;
  border-radius: 0;
  line-height: 1.25;
  overflow-wrap: break-word;
  white-space: normal;
  word-break: normal;
}

.config-select__item:hover,
.config-select__item:focus-visible {
  background: var(--color-surface-muted);
}

.config-select__submenu {
  position: relative;
}

.config-select__submenu-menu {
  overflow-y: auto;
  overscroll-behavior: contain;
  max-height: calc(100vh - 16px);
}

.config-select__submenu-menu--floating {
  position: fixed;
}

.config-select__submenu-trigger {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.config-select__submenu-label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
}
</style>
