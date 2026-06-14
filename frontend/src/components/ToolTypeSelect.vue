<template>
  <div ref="rootRef" class="tool-type-select" :class="{ 'tool-type-select--disabled': disabled }">
    <button
      type="button"
      class="tool-type-select__trigger full"
      :disabled="disabled"
      :title="title"
      aria-haspopup="listbox"
      :aria-expanded="menuOpen"
      @click.stop="toggleMenu"
      @keydown.down.prevent="openMenu"
      @keydown.enter.prevent="toggleMenu"
      @keydown.space.prevent="toggleMenu"
      @keydown.esc="handleEscape"
    >
      <ToolTypeBadge :type="selectedOption.type" :typeTitle="selectedOption.title" />
      <span class="tool-type-select__chevron" aria-hidden="true">▾</span>
    </button>

    <div v-if="menuOpen" class="tool-type-select__menu" role="listbox">
      <button
        v-for="option in normalizedOptions"
        :key="option.type"
        type="button"
        class="tool-type-select__option"
        :class="{ active: option.type === modelValue }"
        role="option"
        :aria-selected="option.type === modelValue"
        @click.stop="selectOption(option.type)"
      >
        <span v-if="option.type === modelValue" class="tool-type-select__check" aria-hidden="true">✓</span>
        <span v-else class="tool-type-select__check" aria-hidden="true"></span>
        <ToolTypeBadge :type="option.type" :typeTitle="option.title" />
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';
import ToolTypeBadge from '@/components/ToolTypeBadge.vue';
import { toolTypeLabel } from '@/features/tools/model/toolInstances';

type ToolTypeOption = {
  type: string;
  title?: string | null;
};

const props = withDefaults(
  defineProps<{
    modelValue: string;
    options: ToolTypeOption[];
    disabled?: boolean;
    title?: string;
  }>(),
  {
    disabled: false,
    title: '',
  }
);

const emit = defineEmits<{
  (e: 'update:modelValue', value: string): void;
  (e: 'change', value: string): void;
}>();

const rootRef = ref<HTMLElement | null>(null);
const menuOpen = ref(false);

const normalizedOptions = computed<ToolTypeOption[]>(() => {
  const byType = new Map<string, ToolTypeOption>();

  for (const option of props.options || []) {
    const type = String(option.type || '').trim();
    if (type) byType.set(type, { type, title: option.title ?? null });
  }

  const currentType = String(props.modelValue || '').trim();
  if (currentType && !byType.has(currentType)) {
    byType.set(currentType, { type: currentType, title: toolTypeLabel({ type: currentType, type_title: null }) });
  }

  return Array.from(byType.values());
});

const selectedOption = computed<ToolTypeOption>(() => {
  const currentType = String(props.modelValue || '').trim();
  return (
    normalizedOptions.value.find((option) => option.type === currentType) || {
      type: currentType,
      title: toolTypeLabel({ type: currentType, type_title: null }),
    }
  );
});

function openMenu() {
  if (props.disabled || !normalizedOptions.value.length) return;
  menuOpen.value = true;
}

function closeMenu() {
  menuOpen.value = false;
}

function handleEscape(event: KeyboardEvent) {
  if (!menuOpen.value) return;
  event.preventDefault();
  event.stopPropagation();
  closeMenu();
}

function toggleMenu() {
  if (props.disabled || !normalizedOptions.value.length) return;
  menuOpen.value = !menuOpen.value;
}

function selectOption(type: string) {
  emit('update:modelValue', type);
  emit('change', type);
  closeMenu();
}

function handleDocumentPointerDown(event: PointerEvent) {
  const target = event.target;
  if (!(target instanceof Node)) return;
  if (!rootRef.value?.contains(target)) closeMenu();
}

onMounted(() => {
  document.addEventListener('pointerdown', handleDocumentPointerDown);
});

onBeforeUnmount(() => {
  document.removeEventListener('pointerdown', handleDocumentPointerDown);
});
</script>

<style scoped>
.tool-type-select {
  position: relative;
  width: 100%;
}

.tool-type-select__trigger {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  width: 100%;
  min-height: 42px;
  text-align: left;
  background: var(--color-surface);
}

.tool-type-select__trigger:disabled {
  cursor: not-allowed;
}

.tool-type-select__chevron {
  flex: 0 0 auto;
  color: var(--color-text-muted);
  font-size: 0.8rem;
}

.tool-type-select__menu {
  position: absolute;
  z-index: 30;
  top: calc(100% + 6px);
  left: 0;
  right: 0;
  display: grid;
  gap: 3px;
  max-height: min(320px, 48vh);
  overflow: auto;
  padding: 6px;
  border: 1px solid var(--color-border-strong);
  border-radius: 8px;
  background: var(--color-surface);
  box-shadow: var(--shadow-menu);
}

.tool-type-select__option {
  display: grid;
  grid-template-columns: 20px minmax(0, 1fr);
  align-items: center;
  gap: 6px;
  width: 100%;
  min-height: 34px;
  padding: 7px 10px;
  border: 0;
  border-radius: 6px;
  background: transparent;
  color: inherit;
  text-align: left;
  cursor: pointer;
}

.tool-type-select__option:hover,
.tool-type-select__option:focus-visible,
.tool-type-select__option.active {
  background: var(--color-info-bg-strong);
  outline: none;
}

.tool-type-select__check {
  color: var(--color-link);
  font-weight: 700;
  text-align: center;
}
</style>
