<template>
  <StackToolbarTeleport>
    <div class="toolbar crud-toolbar fill">
      <strong>{{ title }}</strong>
      <div class="header-actions crud-actions toolbar-actions-right">
        <button
          v-if="dirty"
          :class="['primary', dirty && 'dirty']"
          :disabled="saving"
          @click="emitSave"
        >
          Save
        </button>
        <button v-if="dirty" type="button" :disabled="saving" @click="emitCancel">Cancel</button>
        <button v-else type="button" :disabled="saving" @click="emitClose">Close</button>

        <div class="menu crud-menu" ref="menuAnchorRef">
          <button
            class="icon-button"
            type="button"
            ref="menuButtonRef"
            @click.stop="toggleMenu"
            aria-label="More actions"
          >
            ⋯
          </button>
        </div>

        <div class="crud-inline-extra">
          <button class="desktop-only" type="button" @click="emitCreate">Create</button>
          <button
            class="nav-btn"
            type="button"
            :disabled="navDisabled"
            @click="emitPrev"
            aria-label="Previous"
          >
            ‹
          </button>
          <span v-if="position && total" class="muted inline-meta">{{ position }}/{{ total }}</span>
          <button
            class="nav-btn"
            type="button"
            :disabled="navDisabled"
            @click="emitNext"
            aria-label="Next"
          >
            ›
          </button>
        </div>

        <Teleport to="body">
          <div
            class="dropdown floating-dropdown"
            v-if="menuOpen"
            ref="menuRef"
            :style="menuStyle"
            @click="handleMenuClick"
          >
            <button class="menu-item" type="button" @click="emitCreate">Create</button>
            <button v-if="showDuplicate" class="menu-item" type="button" @click="emitDuplicate">
              Duplicate
            </button>
            <button v-if="showDelete" class="menu-item danger" type="button" @click="emitDelete">
              Delete
            </button>
            <slot name="menu-extra"></slot>
            <div class="menu-divider"></div>
            <button class="menu-item" type="button" :disabled="navDisabled" @click="emitPrev">Prev</button>
            <button class="menu-item" type="button" :disabled="navDisabled" @click="emitNext">Next</button>
            <div v-if="position && total" class="menu-meta">{{ position }}/{{ total }}</div>
          </div>
        </Teleport>
      </div>
    </div>
  </StackToolbarTeleport>
</template>

<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue';
import { Teleport } from 'vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { useStackLayer } from '@/features/stack/useStackLayer';

const props = defineProps<{
  title: string;
  dirty?: boolean;
  position?: number | string;
  total?: number | string;
  navDisabled?: boolean;
  showDelete?: boolean;
  saving?: boolean;
  showDuplicate?: boolean;
}>();

const emit = defineEmits(['create', 'save', 'delete', 'cancel', 'close', 'prev', 'next', 'duplicate']);
const layer = useStackLayer();

const menuOpen = ref(false);
const menuRef = ref<HTMLElement | null>(null);
const menuAnchorRef = ref<HTMLElement | null>(null);
const menuButtonRef = ref<HTMLElement | null>(null);
const menuStyle = ref<Record<string, string>>({});

const toggleMenu = () => {
  menuOpen.value = !menuOpen.value;
  if (menuOpen.value) updateMenuPosition();
};

const closeMenu = () => {
  menuOpen.value = false;
  menuStyle.value = {};
};

const handleClickOutside = (event: MouseEvent) => {
  const target = event.target as Node | null;
  if (!menuRef.value || !target) return;
  if (menuRef.value.contains(target)) return;
  if (menuButtonRef.value && menuButtonRef.value.contains(target)) return;
  closeMenu();
};

const handleMenuClick = (event: MouseEvent) => {
  const target = event.target instanceof Element ? event.target : null;
  if (!target?.closest('button,a[href],[role="button"],[role="menuitem"]')) return;
  closeMenu();
};

const isPrimarySaveShortcut = (event: KeyboardEvent) => {
  if (!(event.ctrlKey || event.metaKey) || event.altKey || event.shiftKey) return false;
  return event.code === 'KeyS' || event.key.toLowerCase() === 's';
};

const isVisibleElement = (element: HTMLElement) => {
  const style = window.getComputedStyle(element);
  if (style.display === 'none' || style.visibility === 'hidden') return false;
  return element.getClientRects().length > 0;
};

const hasOpenModal = () =>
  Array.from(document.querySelectorAll<HTMLElement>('[role="dialog"][aria-modal="true"]')).some(isVisibleElement);

const isEscapeFromNativeSelect = (event: KeyboardEvent) =>
  event.key === 'Escape' && event.target instanceof Element && Boolean(event.target.closest('select'));

const handleGlobalKeydown = (event: KeyboardEvent) => {
  if (!layer.active.value || event.defaultPrevented || event.isComposing) return;

  const modalOpen = hasOpenModal();

  if (isPrimarySaveShortcut(event)) {
    event.preventDefault();
    if (!modalOpen && props.dirty && !props.saving) emitSave();
    return;
  }

  if (modalOpen || isEscapeFromNativeSelect(event)) return;

  if (event.key !== 'Escape') return;

  if (menuOpen.value) {
    event.preventDefault();
    closeMenu();
    return;
  }

  if (props.saving) return;

  event.preventDefault();
  if (props.dirty) emitCancel();
  else emitClose();
};

onMounted(() => {
  document.addEventListener('click', handleClickOutside);
  window.addEventListener('keydown', handleGlobalKeydown);
  window.addEventListener('resize', updateMenuPosition);
  window.addEventListener('scroll', updateMenuPosition, true);
});

onBeforeUnmount(() => {
  document.removeEventListener('click', handleClickOutside);
  window.removeEventListener('keydown', handleGlobalKeydown);
  window.removeEventListener('resize', updateMenuPosition);
  window.removeEventListener('scroll', updateMenuPosition, true);
});

const updateMenuPosition = () => {
  if (!menuOpen.value) return;
  const btn = menuButtonRef.value;
  if (!btn) return;
  const rect = btn.getBoundingClientRect();
  const minWidth = 180;
  menuStyle.value = {
    position: 'fixed',
    top: `${rect.bottom + 6}px`,
    left: `${rect.right - minWidth}px`,
    minWidth: `${minWidth}px`,
    zIndex: '2000',
  };
};

const emitCreate = () => {
  emit('create');
  closeMenu();
};

const emitSave = () => emit('save');
const emitCancel = () => emit('cancel');
const emitClose = () => emit('close');

const emitDelete = () => {
  emit('delete');
  closeMenu();
};

const emitPrev = () => {
  emit('prev');
  closeMenu();
};

const emitNext = () => {
  emit('next');
  closeMenu();
};

const emitDuplicate = () => {
  emit('duplicate');
  closeMenu();
};
</script>

<style scoped>
.crud-inline-extra {
  display: flex;
  align-items: center;
  gap: 8px;
}

.nav-btn {
  width: 32px;
  padding: 6px 0;
}

.menu.crud-menu {
  margin-left: 8px;
}

@media (max-width: 720px) {
  .crud-inline-extra .desktop-only {
    display: none;
  }
}
</style>
