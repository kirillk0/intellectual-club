<template>
  <StackToolbarTeleport>
    <div class="toolbar crud-toolbar fill">
      <strong class="crud-title">{{ title }}</strong>
      <div class="header-actions crud-actions toolbar-actions-right">
        <button
          v-if="dirty"
          class="icon-button icon-button--labeled crud-icon-button primary dirty"
          type="button"
          :disabled="saving"
          aria-label="Save"
          title="Save"
          @click="emitSave"
        >
          <SvgIcon name="save" size="16" />
          <span class="icon-button__label">Save</span>
        </button>

        <button
          v-if="dirty"
          class="icon-button icon-button--labeled crud-icon-button"
          type="button"
          :disabled="saving"
          aria-label="Cancel"
          title="Cancel"
          @click="emitCancel"
        >
          <SvgIcon name="undo" size="16" />
          <span class="icon-button__label">Cancel</span>
        </button>

        <div class="crud-action-group">
          <button
            class="icon-button icon-button--labeled crud-icon-button"
            type="button"
            aria-label="Create"
            title="Create"
            @click="emitCreate"
          >
            <SvgIcon name="plus" size="16" />
            <span class="icon-button__label">Create</span>
          </button>
          <button
            v-if="showDuplicate"
            class="icon-button icon-button--labeled crud-icon-button"
            type="button"
            aria-label="Duplicate"
            title="Duplicate"
            @click="emitDuplicate"
          >
            <SvgIcon name="copy" size="16" />
            <span class="icon-button__label">Duplicate</span>
          </button>
          <slot name="extra-actions"></slot>
          <button
            v-if="showDelete"
            class="icon-button icon-button--labeled crud-icon-button danger"
            type="button"
            aria-label="Delete"
            title="Delete"
            @click="emitDelete"
          >
            <SvgIcon name="delete" size="16" />
            <span class="icon-button__label">Delete</span>
          </button>
        </div>

        <div class="crud-action-group crud-nav-actions">
          <button
            class="icon-button crud-icon-button nav-btn"
            type="button"
            :disabled="navDisabled"
            @click="emitPrev"
            aria-label="Previous"
            title="Previous"
          >
            <SvgIcon name="chevron-left" size="16" />
          </button>
          <span v-if="position && total" class="muted inline-meta crud-record-position">{{ position }}/{{ total }}</span>
          <button
            class="icon-button crud-icon-button nav-btn"
            type="button"
            :disabled="navDisabled"
            @click="emitNext"
            aria-label="Next"
            title="Next"
          >
            <SvgIcon name="chevron-right" size="16" />
          </button>
        </div>

        <button
          v-if="!dirty"
          class="icon-button icon-button--labeled crud-icon-button crud-close-button"
          type="button"
          :disabled="saving"
          aria-label="Close"
          title="Close"
          @click="emitClose"
        >
          <SvgIcon name="x" size="16" />
          <span class="icon-button__label">Close</span>
        </button>
      </div>
    </div>
  </StackToolbarTeleport>
</template>

<script setup lang="ts">
import { onBeforeUnmount, onMounted } from 'vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
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

  if (props.saving) return;

  event.preventDefault();
  if (props.dirty) emitCancel();
  else emitClose();
};

onMounted(() => {
  window.addEventListener('keydown', handleGlobalKeydown);
});

onBeforeUnmount(() => {
  window.removeEventListener('keydown', handleGlobalKeydown);
});

const emitCreate = () => emit('create');
const emitSave = () => emit('save');
const emitCancel = () => emit('cancel');
const emitClose = () => emit('close');
const emitDelete = () => emit('delete');
const emitPrev = () => emit('prev');
const emitNext = () => emit('next');
const emitDuplicate = () => emit('duplicate');
</script>
