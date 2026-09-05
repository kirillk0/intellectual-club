<template>
  <div
    ref="configMenuRef"
    class="config-select"
    :class="{ 'config-select--disabled': disabled, 'config-select--open': configMenuOpen }"
    @click.stop
    @keydown="handleMenuKeydown"
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
        :aria-label="t('Configuration')"
        tabindex="-1"
        :style="configMenuStyle"
        @click.stop
        @keydown="handleMenuKeydown"
      >
        <template v-if="searchVisible">
          <div class="config-select__search">
            <input
              ref="searchInputRef"
              v-model="searchQuery"
              type="search"
              :placeholder="t('Search configurations')"
              :aria-label="t('Search configurations')"
              autocomplete="off"
              autocapitalize="off"
              :spellcheck="false"
            />
          </div>
          <button
            v-for="item in searchResults"
            :key="item.key"
            class="config-select__item"
            type="button"
            role="menuitem"
            :title="item.title"
            @click="selectConfig(item.value)"
          >
            {{ item.label }}
          </button>
          <div v-if="!searchResults.length" class="config-select__empty" role="status">
            {{ t('No configurations found.') }}
          </div>
        </template>
        <template v-else>
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
          <div class="config-select__footer">
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
                <span class="config-select__submenu-label">{{ t('More') }}</span>
                <span aria-hidden="true">‹</span>
              </button>
            </div>
            <button
              type="button"
              class="config-select__search-toggle"
              :aria-label="t('Search configurations')"
              :title="t('Type to search all configurations')"
              @click="showSearch()"
            >
              <SvgIcon name="tool-search" size="16" />
            </button>
          </div>
        </template>
      </div>
    </Teleport>

    <Teleport to="body">
      <div
        v-if="configMenuOpen && moreMenuOpen"
        ref="moreDropdownRef"
        class="config-select__submenu-menu config-select__submenu-menu--floating"
        role="menu"
        :aria-label="t('More configurations')"
        :style="moreMenuStyle"
        @click.stop
        @mouseenter="cancelMoreConfigMenuClose"
        @pointerenter="cancelMoreConfigMenuClose"
        @mouseleave="scheduleCloseMoreConfigMenu"
        @pointerleave="scheduleCloseMoreConfigMenu"
        @keydown="handleMenuKeydown"
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
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue';

import SvgIcon from '@/components/icons/SvgIcon.vue';
import { translate as t } from '@/i18n';
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
const searchInputRef = ref<HTMLInputElement | null>(null);
const searchVisible = ref(false);
const searchQuery = ref('');
const configMenuOpen = ref(false);
const moreMenuOpen = ref(false);
const configMenuStyle = ref<Record<string, string>>({});
const moreMenuStyle = ref<Record<string, string>>({});
let moreMenuOpenTimer: number | null = null;
let moreMenuCloseTimer: number | null = null;

const moreConfigReason = (config: LlmConfiguration) => {
  if (config.enabled === false) return ` ${t('(disabled)')}`;
  return ` ${t('(incompatible)')}`;
};

const moreMenuItems = computed<MoreMenuItem[]>(() => [
  {
    key: 'no-config',
    label: t('No config'),
    title: t('No config'),
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

const searchResults = computed<MoreMenuItem[]>(() => {
  const query = searchQuery.value.trim().toLocaleLowerCase();
  const items = [
    ...props.selectableConfigs.map((config) => {
      const label = props.configLabel(config);
      return { key: String(config.id), label, title: label, value: config.id };
    }),
    ...moreMenuItems.value,
  ];
  return items.filter((item) => item.label.toLocaleLowerCase().includes(query));
});

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
  searchVisible.value = false;
  searchQuery.value = '';
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
  configDropdownRef.value?.focus({ preventScroll: true });
};

const showSearch = async (query = searchQuery.value) => {
  cancelMoreConfigMenuOpen();
  cancelMoreConfigMenuClose();
  moreMenuOpen.value = false;
  searchQuery.value = query;
  searchVisible.value = true;
  await nextTick();
  searchInputRef.value?.focus({ preventScroll: true });
};

const handleMenuKeydown = async (event: KeyboardEvent) => {
  if (props.disabled || event.isComposing || event.ctrlKey || event.metaKey || event.altKey) return;
  if (event.key === 'Escape' && configMenuOpen.value) {
    event.preventDefault();
    event.stopPropagation();
    closeConfigMenu();
    configTriggerRef.value?.focus({ preventScroll: true });
    return;
  }

  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    event.preventDefault();
    if (!configMenuOpen.value) await openConfigMenu();
    const menu = moreDropdownRef.value?.contains(event.target as Node)
      ? moreDropdownRef.value
      : configDropdownRef.value;
    const items = Array.from(menu?.querySelectorAll<HTMLButtonElement>('[role="menuitem"]') ?? []);
    if (!items.length) return;
    const index = items.indexOf(document.activeElement as HTMLButtonElement);
    const nextIndex = event.key === 'ArrowDown' ? index + 1 : (index < 0 ? 0 : index) - 1;
    items[(nextIndex + items.length) % items.length]?.focus();
    return;
  }

  if (event.target === searchInputRef.value) {
    if (event.key === 'Enter') {
      event.preventDefault();
      const firstResult = searchResults.value[0];
      if (firstResult) selectConfig(firstResult.value);
    }
    return;
  }

  if (event.key.length !== 1 || !event.key.trim()) return;
  event.preventDefault();
  if (!configMenuOpen.value) await openConfigMenu();
  await showSearch(searchQuery.value + event.key);
};

watch([searchQuery, searchVisible], updateConfigMenuPosition, { flush: 'post' });

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
  if (!configMenuOpen.value || searchVisible.value || !moreMenuItems.value.length) return;
  cancelMoreConfigMenuOpen();
  cancelMoreConfigMenuClose();
  moreMenuOpen.value = true;
  await nextTick();
  updateMoreMenuPosition();
};

const scheduleOpenMoreConfigMenu = () => {
  if (!configMenuOpen.value || searchVisible.value || !moreMenuItems.value.length) return;
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
  configTriggerRef.value?.focus({ preventScroll: true });
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
  flex: 1;
  min-width: 0;
}

.config-select__footer {
  display: flex;
  align-items: stretch;
}

.config-select__search-toggle {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 40px;
  border: none;
  border-radius: 0;
  background: transparent;
  color: var(--color-text-muted);
}

.config-select__search-toggle:hover,
.config-select__search-toggle:focus-visible {
  background: var(--color-surface-muted);
}

.config-select__search {
  position: sticky;
  top: -6px;
  padding: 6px 10px;
  background: var(--color-surface);
}

.config-select__search input {
  width: 100%;
  min-width: 0;
  box-sizing: border-box;
  font-size: 16px;
}

.config-select__empty {
  padding: 9px 12px;
  color: var(--color-text-muted);
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
