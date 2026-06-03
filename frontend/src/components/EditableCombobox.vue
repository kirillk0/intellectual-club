<template>
  <div ref="rootRef" class="combo-box">
    <div class="combo-box__row">
      <input
        :value="modelValue"
        class="full combo-box__input"
        :placeholder="placeholder"
        :disabled="disabled"
        autocomplete="off"
        aria-autocomplete="list"
        :aria-expanded="options.length ? String(menuOpen) : undefined"
        aria-haspopup="listbox"
        @focus="openMenu"
        @input="handleInput"
        @keydown.down.prevent="openMenu"
        @keydown.esc="closeMenu"
      />
      <button
        v-if="options.length"
        type="button"
        class="combo-box__toggle"
        :disabled="disabled"
        :aria-expanded="String(menuOpen)"
        :aria-label="toggleLabel"
        @click="toggleMenu"
      >
        ▼
      </button>
    </div>
    <div v-if="options.length && menuOpen" class="combo-box__menu" role="listbox">
      <button
        v-for="option in options"
        :key="option"
        type="button"
        class="combo-box__option"
        :class="{ active: modelValue === option }"
        @click="selectOption(option)"
      >
        {{ option }}
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch } from 'vue';

type Props = {
  modelValue: string;
  options: string[];
  placeholder?: string;
  toggleLabel?: string;
  disabled?: boolean;
};

const props = withDefaults(defineProps<Props>(), {
  placeholder: '',
  toggleLabel: 'Show options',
  disabled: false,
});

const emit = defineEmits<{
  (e: 'update:modelValue', value: string): void;
}>();

const rootRef = ref<HTMLElement | null>(null);
const menuOpen = ref(false);
const suppressOpenUntilInput = ref(false);

watch(
  () => props.options,
  (options) => {
    if (!options.length) {
      menuOpen.value = false;
    }
  }
);

const openMenu = () => {
  if (props.disabled) return;
  if (suppressOpenUntilInput.value) return;
  if (props.options.length) {
    menuOpen.value = true;
  }
};

const closeMenu = () => {
  menuOpen.value = false;
};

const toggleMenu = () => {
  if (props.disabled) return;
  if (!props.options.length) return;
  suppressOpenUntilInput.value = false;
  menuOpen.value = !menuOpen.value;
};

const selectOption = (option: string) => {
  suppressOpenUntilInput.value = true;
  emit('update:modelValue', option);
  closeMenu();
};

const handleInput = (event: Event) => {
  const target = event.target;
  if (!(target instanceof HTMLInputElement)) return;
  if (props.disabled) return;
  suppressOpenUntilInput.value = false;
  emit('update:modelValue', target.value);
  openMenu();
};

const handleDocumentPointerDown = (event: PointerEvent) => {
  const target = event.target;
  if (!(target instanceof Node)) return;
  if (!rootRef.value?.contains(target)) {
    closeMenu();
  }
};

onMounted(() => {
  document.addEventListener('pointerdown', handleDocumentPointerDown);
});

onBeforeUnmount(() => {
  document.removeEventListener('pointerdown', handleDocumentPointerDown);
});
</script>

<style scoped>
.combo-box {
  position: relative;
}

.combo-box__row {
  display: flex;
  gap: 8px;
  align-items: stretch;
}

.combo-box__input {
  min-width: 0;
}

.combo-box__toggle {
  flex: 0 0 auto;
  min-width: 42px;
  padding: 0 12px;
}

.combo-box__menu {
  position: absolute;
  z-index: 10;
  top: calc(100% + 6px);
  left: 0;
  right: 0;
  display: grid;
  gap: 4px;
  padding: 6px;
  border: 1px solid var(--color-border-strong);
  border-radius: 10px;
  background: var(--color-surface);
  box-shadow: var(--shadow-menu);
}

.combo-box__option {
  width: 100%;
  padding: 8px 10px;
  border: 0;
  border-radius: 8px;
  background: transparent;
  color: inherit;
  text-align: left;
  cursor: pointer;
}

.combo-box__option:hover,
.combo-box__option:focus-visible,
.combo-box__option.active {
  background: var(--color-info-bg-strong);
  outline: none;
}
</style>
