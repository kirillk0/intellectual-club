<template>
  <Teleport to="body">
    <div
      v-if="anchor"
      ref="menuRef"
      class="dropdown floating-dropdown chat-list-actions-menu"
      role="menu"
      :aria-label="t('Chat actions')"
      :style="menuStyle"
    >
      <button
        class="menu-item chat-list-actions-menu__item"
        type="button"
        role="menuitem"
        :disabled="deleting"
        @click="emit('edit-note')"
      >
        <span class="chat-list-actions-menu__icon" aria-hidden="true">
          <SvgIcon name="edit" size="16" />
        </span>
        <span class="chat-list-actions-menu__label">{{ t('Edit note') }}</span>
      </button>
      <button
        class="menu-item chat-list-actions-menu__item danger"
        type="button"
        role="menuitem"
        :disabled="deleting"
        @click="emit('delete')"
      >
        <span class="chat-list-actions-menu__icon" aria-hidden="true">
          <SvgIcon name="delete" size="16" />
        </span>
        <span class="chat-list-actions-menu__label">{{ t(deleting ? 'Deleting…' : 'Delete') }}</span>
      </button>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { nextTick, onBeforeUnmount, ref, watch } from 'vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { translate } from '@/i18n';

export type ChatListActionsAnchor = {
  /** Horizontal anchor point in viewport coordinates. */
  x: number;
  /** Preferred top edge of the menu in viewport coordinates. */
  y: number;
  /** Bottom edge used when the menu has to open upwards; defaults to `y`. */
  flipY?: number;
  /** `end` aligns the menu's right edge to `x` (trigger buttons), `start` its left edge (pointer). */
  align: 'start' | 'end';
};

const props = withDefaults(
  defineProps<{
    anchor: ChatListActionsAnchor | null;
    deleting?: boolean;
  }>(),
  {
    deleting: false,
  }
);

const emit = defineEmits<{
  close: [];
  'edit-note': [];
  delete: [];
}>();

const t = translate;

const VIEWPORT_PADDING = 8;
const TRIGGER_SELECTOR = '[data-chat-actions-trigger]';

const menuRef = ref<HTMLElement | null>(null);
const menuStyle = ref<Record<string, string>>({});
let listening = false;

// Measure at the viewport origin so the menu is not squeezed by the right edge before placement.
const MEASURE_STYLE: Record<string, string> = {
  position: 'fixed',
  top: '0px',
  left: '0px',
  right: 'auto',
  zIndex: '2000',
  visibility: 'hidden',
};

function placeMenu(anchor: ChatListActionsAnchor) {
  const menu = menuRef.value;
  if (!menu) return;

  const { width, height } = menu.getBoundingClientRect();
  const maxLeft = Math.max(VIEWPORT_PADDING, window.innerWidth - width - VIEWPORT_PADDING);
  const preferredLeft = anchor.align === 'end' ? anchor.x - width : anchor.x;
  const left = Math.min(Math.max(VIEWPORT_PADDING, preferredLeft), maxLeft);

  const fitsBelow = anchor.y + height <= window.innerHeight - VIEWPORT_PADDING;
  const upwardTop = (anchor.flipY ?? anchor.y) - height;
  const top = fitsBelow || upwardTop < VIEWPORT_PADDING
    ? Math.max(VIEWPORT_PADDING, Math.min(anchor.y, window.innerHeight - height - VIEWPORT_PADDING))
    : upwardTop;

  menuStyle.value = {
    position: 'fixed',
    top: `${top}px`,
    left: `${left}px`,
    right: 'auto',
    zIndex: '2000',
  };
}

function handlePointerDown(event: PointerEvent) {
  const target = event.target as Element | null;
  if (!target) return;
  if (menuRef.value?.contains(target)) return;
  // Trigger buttons toggle the menu themselves on click.
  if (target.closest(TRIGGER_SELECTOR)) return;
  emit('close');
}

function handleKeydown(event: KeyboardEvent) {
  if (event.key !== 'Escape') return;
  event.preventDefault();
  emit('close');
}

function handleViewportChange(event: Event) {
  if (event.type === 'scroll' && menuRef.value?.contains(event.target as Node | null)) return;
  emit('close');
}

function startListening() {
  if (listening) return;
  listening = true;
  document.addEventListener('pointerdown', handlePointerDown, true);
  document.addEventListener('keydown', handleKeydown);
  window.addEventListener('resize', handleViewportChange);
  window.addEventListener('scroll', handleViewportChange, true);
  window.addEventListener('blur', handleViewportChange);
}

function stopListening() {
  if (!listening) return;
  listening = false;
  document.removeEventListener('pointerdown', handlePointerDown, true);
  document.removeEventListener('keydown', handleKeydown);
  window.removeEventListener('resize', handleViewportChange);
  window.removeEventListener('scroll', handleViewportChange, true);
  window.removeEventListener('blur', handleViewportChange);
}

watch(
  () => props.anchor,
  async (anchor) => {
    if (!anchor) {
      stopListening();
      menuStyle.value = {};
      return;
    }

    menuStyle.value = MEASURE_STYLE;
    startListening();
    await nextTick();
    if (props.anchor === anchor) placeMenu(anchor);
  },
  { immediate: true }
);

onBeforeUnmount(stopListening);
</script>

<style scoped>
.chat-list-actions-menu {
  min-width: 180px;
}

.chat-list-actions-menu__item {
  display: flex;
  align-items: center;
  gap: 10px;
}

.chat-list-actions-menu__icon {
  width: 18px;
  display: inline-flex;
  justify-content: center;
  color: var(--color-text-muted);
}

.chat-list-actions-menu__item.danger .chat-list-actions-menu__icon {
  color: inherit;
}

.chat-list-actions-menu__item .svg-icon {
  stroke-width: 1.35;
}

.chat-list-actions-menu__label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
</style>
