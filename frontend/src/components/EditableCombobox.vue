<template>
  <div ref="rootRef" class="combo-box">
    <div class="combo-box__row">
      <input
        :value="modelValue"
        class="full combo-box__input"
        :placeholder="placeholder"
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
};

const props = withDefaults(defineProps<Props>(), {
  placeholder: '',
  toggleLabel: 'Show options',
});

const emit = defineEmits<{
  (e: 'update:modelValue', value: string): void;
}>();

const rootRef = ref<HTMLElement | null>(null);
const menuOpen = ref(false);

watch(
  () => props.options,
  (options) => {
    if (!options.length) {
      menuOpen.value = false;
    }
  }
);

const openMenu = () => {
  if (props.options.length) {
    menuOpen.value = true;
  }
};

const closeMenu = () => {
  menuOpen.value = false;
};

const toggleMenu = () => {
  if (!props.options.length) return;
  menuOpen.value = !menuOpen.value;
};

const selectOption = (option: string) => {
  emit('update:modelValue', option);
  closeMenu();
};

const handleInput = (event: Event) => {
  const target = event.target;
  if (!(target instanceof HTMLInputElement)) return;
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
  border: 1px solid #d0d7de;
  border-radius: 10px;
  background: #fff;
  box-shadow: 0 10px 24px rgba(15, 23, 42, 0.12);
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
  background: #eef4ff;
  outline: none;
}
</style>
