<template>
  <Teleport to="body">
    <transition name="fade">
      <div
        v-if="open"
        class="modal-backdrop"
        :class="backdropClass"
        @click.self="handleBackdropClick"
        @touchmove="emit('backdrop-touchmove', $event)"
      >
        <div
          ref="modalRef"
          v-bind="modalAttrs"
          class="modal"
          :class="modalClass"
          :style="resolvedModalStyle"
          role="dialog"
          aria-modal="true"
          :aria-label="modalAriaLabel"
          :aria-labelledby="modalAriaLabelledby"
          tabindex="-1"
        >
          <slot />
        </div>
      </div>
    </transition>
  </Teleport>
</template>

<script lang="ts">
let nextModalId = 0;
const openModalStack: number[] = [];

type DocumentScrollLockSnapshot = {
  scrollX: number;
  scrollY: number;
  rootOverflow: string;
  rootOverscrollBehavior: string;
  bodyPosition: string;
  bodyTop: string;
  bodyLeft: string;
  bodyRight: string;
  bodyWidth: string;
  bodyOverflow: string;
  bodyOverscrollBehavior: string;
  bodyPaddingRight: string;
};

let documentScrollLockCount = 0;
let documentScrollLockSnapshot: DocumentScrollLockSnapshot | null = null;

function lockDocumentScroll() {
  documentScrollLockCount += 1;
  if (documentScrollLockCount > 1) return;

  const root = document.documentElement;
  const body = document.body;
  const scrollX = window.scrollX;
  const scrollY = window.scrollY;
  const scrollbarWidth = root.clientWidth > 0 ? Math.max(0, window.innerWidth - root.clientWidth) : 0;
  const bodyPaddingRight = Number.parseFloat(window.getComputedStyle(body).paddingRight) || 0;

  documentScrollLockSnapshot = {
    scrollX,
    scrollY,
    rootOverflow: root.style.overflow,
    rootOverscrollBehavior: root.style.overscrollBehavior,
    bodyPosition: body.style.position,
    bodyTop: body.style.top,
    bodyLeft: body.style.left,
    bodyRight: body.style.right,
    bodyWidth: body.style.width,
    bodyOverflow: body.style.overflow,
    bodyOverscrollBehavior: body.style.overscrollBehavior,
    bodyPaddingRight: body.style.paddingRight,
  };

  root.style.overflow = 'hidden';
  root.style.overscrollBehavior = 'none';
  body.style.position = 'fixed';
  body.style.top = `-${scrollY}px`;
  body.style.left = `-${scrollX}px`;
  body.style.right = '0';
  body.style.width = '100%';
  body.style.overflow = 'hidden';
  body.style.overscrollBehavior = 'none';
  if (scrollbarWidth > 0) body.style.paddingRight = `${bodyPaddingRight + scrollbarWidth}px`;
}

function unlockDocumentScroll() {
  if (documentScrollLockCount === 0) return;
  documentScrollLockCount -= 1;
  if (documentScrollLockCount > 0) return;

  const snapshot = documentScrollLockSnapshot;
  documentScrollLockSnapshot = null;
  if (!snapshot) return;

  const root = document.documentElement;
  const body = document.body;
  root.style.overflow = snapshot.rootOverflow;
  root.style.overscrollBehavior = snapshot.rootOverscrollBehavior;
  body.style.position = snapshot.bodyPosition;
  body.style.top = snapshot.bodyTop;
  body.style.left = snapshot.bodyLeft;
  body.style.right = snapshot.bodyRight;
  body.style.width = snapshot.bodyWidth;
  body.style.overflow = snapshot.bodyOverflow;
  body.style.overscrollBehavior = snapshot.bodyOverscrollBehavior;
  body.style.paddingRight = snapshot.bodyPaddingRight;
  window.scrollTo(snapshot.scrollX, snapshot.scrollY);
}
</script>

<script setup lang="ts">
import {
  computed,
  nextTick,
  onBeforeUnmount,
  ref,
  useAttrs,
  watch,
  type CSSProperties,
} from 'vue';

type ClassValue = string | Record<string, boolean> | Array<string | Record<string, boolean>>;
type StyleValue =
  | string
  | CSSProperties
  | Array<string | CSSProperties | null | undefined>
  | null
  | undefined;
type SubmitShortcut = 'none' | 'auto' | 'enter' | 'modifier-enter';

interface Props {
  open?: boolean;
  ariaLabel?: string;
  ariaLabelledby?: string;
  modalClass?: ClassValue;
  backdropClass?: ClassValue;
  modalStyle?: StyleValue;
  maxWidth?: string;
  cancelDisabled?: boolean;
  submitDisabled?: boolean;
  submitShortcut?: SubmitShortcut;
  closeOnBackdrop?: boolean;
}

const props = withDefaults(defineProps<Props>(), {
  open: true,
  ariaLabel: '',
  ariaLabelledby: '',
  modalClass: '',
  backdropClass: '',
  modalStyle: undefined,
  maxWidth: '',
  cancelDisabled: false,
  submitDisabled: false,
  submitShortcut: 'none',
  closeOnBackdrop: true,
});

defineOptions({
  inheritAttrs: false,
});

const emit = defineEmits<{
  (e: 'cancel'): void;
  (e: 'submit'): void;
  (e: 'backdrop-touchmove', event: TouchEvent): void;
}>();

const modalId = nextModalId++;
const modalRef = ref<HTMLElement | null>(null);
const attrs = useAttrs();
let documentScrollLocked = false;

const modalAttrs = computed(() => {
  const { 'aria-label': _ariaLabel, 'aria-labelledby': _ariaLabelledby, ...rest } = attrs;
  return rest;
});

const modalAriaLabel = computed(() => {
  const value = props.ariaLabel || attrs['aria-label'];
  return typeof value === 'string' && value.trim() !== '' ? value : undefined;
});

const modalAriaLabelledby = computed(() => {
  const value = props.ariaLabelledby || attrs['aria-labelledby'];
  return typeof value === 'string' && value.trim() !== '' ? value : undefined;
});

const resolvedModalStyle = computed<StyleValue>(() => {
  const maxWidthStyle = props.maxWidth ? ({ maxWidth: props.maxWidth } satisfies CSSProperties) : null;
  if (!props.modalStyle) return maxWidthStyle;
  if (Array.isArray(props.modalStyle)) return maxWidthStyle ? [...props.modalStyle, maxWidthStyle] : props.modalStyle;
  return maxWidthStyle ? [props.modalStyle, maxWidthStyle] : props.modalStyle;
});

function removeFromStack() {
  const index = openModalStack.indexOf(modalId);
  if (index >= 0) openModalStack.splice(index, 1);
}

function pushToStack() {
  removeFromStack();
  openModalStack.push(modalId);
}

function isTopModal() {
  return openModalStack[openModalStack.length - 1] === modalId;
}

function acquireDocumentScrollLock() {
  if (documentScrollLocked) return;
  documentScrollLocked = true;
  lockDocumentScroll();
}

function releaseDocumentScrollLock() {
  if (!documentScrollLocked) return;
  documentScrollLocked = false;
  unlockDocumentScroll();
}

function emitCancel() {
  if (props.cancelDisabled) return;
  emit('cancel');
}

function handleBackdropClick() {
  if (!props.closeOnBackdrop) return;
  emitCancel();
}

function hasMultilineInput() {
  return Boolean(
    modalRef.value?.querySelector(
      'textarea,[contenteditable="true"],[role="textbox"][aria-multiline="true"]'
    )
  );
}

function eventTargetIgnored(event: KeyboardEvent) {
  const target = event.target instanceof Element ? event.target : null;
  if (!target || !modalRef.value?.contains(target)) return false;

  return Boolean(
    target.closest('button,a[href],select,[role="button"],[data-modal-shortcut-ignore]')
  );
}

function isPlainEnter(event: KeyboardEvent) {
  return !event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey;
}

function isModifierEnter(event: KeyboardEvent) {
  return (event.ctrlKey || event.metaKey) && !event.altKey && !event.shiftKey;
}

function shouldSubmitOnEnter(event: KeyboardEvent) {
  if (props.submitShortcut === 'none' || props.submitDisabled) return false;
  if (event.defaultPrevented || event.isComposing || eventTargetIgnored(event)) return false;

  if (props.submitShortcut === 'enter') return isPlainEnter(event);
  if (props.submitShortcut === 'modifier-enter') return isModifierEnter(event);

  return hasMultilineInput() ? isModifierEnter(event) : isPlainEnter(event);
}

function handleKeydown(event: KeyboardEvent) {
  if (!props.open || !isTopModal()) return;

  if (event.key === 'Escape') {
    if (props.cancelDisabled) return;
    event.preventDefault();
    emitCancel();
    return;
  }

  if (event.key !== 'Enter') return;
  if (!shouldSubmitOnEnter(event)) return;

  event.preventDefault();
  emit('submit');
}

function focusModalIfNeeded() {
  void nextTick(() => {
    window.requestAnimationFrame(() => {
      const modal = modalRef.value;
      if (!props.open || !modal) return;
      const activeElement = document.activeElement;
      if (activeElement && modal.contains(activeElement)) return;
      modal.focus({ preventScroll: true });
    });
  });
}

watch(
  () => props.open,
  (open) => {
    if (open) {
      pushToStack();
      acquireDocumentScrollLock();
      window.addEventListener('keydown', handleKeydown);
      focusModalIfNeeded();
      return;
    }

    window.removeEventListener('keydown', handleKeydown);
    removeFromStack();
    releaseDocumentScrollLock();
  },
  { immediate: true }
);

onBeforeUnmount(() => {
  window.removeEventListener('keydown', handleKeydown);
  removeFromStack();
  releaseDocumentScrollLock();
});
</script>
