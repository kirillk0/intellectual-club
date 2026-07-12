<template>
  <div class="stack">
    <div class="knowledge-block-code-field">
      <div class="knowledge-block-code-field__header">
        <div class="knowledge-block-code-field__label">{{ translate(label) }}</div>
        <button
          class="knowledge-block-content-editor__expand"
          type="button"
          :aria-label="translate('Open full-screen editor')"
          :title="translate('Open full-screen editor')"
          @click="openFullscreen"
        >
          <SvgIcon name="code" aria-hidden="true" />
          <span>{{ translate('Expand editor') }}</span>
        </button>
      </div>
      <div
        :class="[
          'knowledge-block-content-editor',
          contentError && 'knowledge-block-content-editor--error',
          readonly && 'knowledge-block-content-editor--readonly',
        ]"
      >
        <div ref="editorRootRef" class="knowledge-block-content-editor__host" data-i18n-ignore></div>
      </div>
      <div v-if="hint" class="muted knowledge-block-content-editor__hint">
        {{ translate(hint) }}
      </div>
      <div v-else class="muted knowledge-block-content-editor__hint">
        Lines starting with <code>//// </code> are treated as comments and removed from the compiled prompt.
      </div>
      <div v-if="contentError" class="error-text">{{ contentError }}</div>
    </div>

    <ModalWindow
      :open="fullscreenOpen"
      backdrop-class="knowledge-block-editor-modal-backdrop"
      modal-class="knowledge-block-editor-modal"
      :aria-label="translate('Full-screen editor')"
      :close-on-backdrop="false"
      submit-shortcut="none"
      @cancel="closeFullscreen"
    >
      <div class="knowledge-block-editor-modal__top">
        <div class="knowledge-block-editor-modal__header">
          <h3>{{ translate(label) }}</h3>
          <div class="knowledge-block-editor-modal__actions">
            <button type="button" @click="closeFullscreen">{{ translate('Done') }}</button>
            <button
              class="icon-button"
              type="button"
              :aria-label="translate('Close editor')"
              :title="translate('Close editor')"
              @click="closeFullscreen"
            >
              <SvgIcon name="x" aria-hidden="true" />
            </button>
          </div>
        </div>
        <div v-if="contentError" class="error-text knowledge-block-editor-modal__error">
          {{ contentError }}
        </div>
      </div>

      <div
        :class="[
          'knowledge-block-content-editor',
          'knowledge-block-content-editor--fullscreen',
          contentError && 'knowledge-block-content-editor--error',
          readonly && 'knowledge-block-content-editor--readonly',
        ]"
      >
        <div
          ref="fullscreenEditorRootRef"
          class="knowledge-block-content-editor__host"
          data-i18n-ignore
        ></div>
      </div>
    </ModalWindow>
  </div>
</template>

<script setup lang="ts">
import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
} from '@codemirror/commands';
import {
  Compartment,
  EditorState,
  Transaction,
} from '@codemirror/state';
import {
  EditorView,
  drawSelection,
  highlightActiveLine,
  keymap,
  placeholder,
  scrollPastEnd,
} from '@codemirror/view';
import {
  highlightSelectionMatches,
  search,
  searchKeymap,
} from '@codemirror/search';
import { nextTick, onBeforeUnmount, onMounted, ref, shallowRef, watch } from 'vue';

import ModalWindow from '@/components/ModalWindow.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { effectiveLocale, translate } from '@/i18n';
import { CODEMIRROR_RU_PHRASES } from '@/utils/codeMirrorPhrases';
import { markdownCodeHighlightingExtensions } from '@/utils/markdownCodeMirror';
import type { KnowledgeBlockCodeEditorExpose } from './types';

const props = withDefaults(
  defineProps<{
    content: string;
    contentError: string | null;
    readonly: boolean;
    label?: string;
    placeholder?: string;
    hint?: string;
  }>(),
  {
    label: 'Content',
    placeholder: 'Write the knowledge block content...',
    hint: '',
  }
);

const emit = defineEmits<{
  (e: 'update:content', value: string): void;
  (e: 'clear-content-error'): void;
}>();

type ManagedEditor = {
  view: EditorView;
  editableCompartment: Compartment;
  localizedCompartment: Compartment;
};

const editorRootRef = ref<HTMLDivElement | null>(null);
const fullscreenEditorRootRef = ref<HTMLDivElement | null>(null);
const inlineEditor = shallowRef<ManagedEditor | null>(null);
const fullscreenEditor = shallowRef<ManagedEditor | null>(null);
const fullscreenOpen = ref(false);
let syncingFromProps = false;

function readonlyExtensions() {
  return [
    EditorState.readOnly.of(props.readonly),
    EditorView.editable.of(!props.readonly),
  ];
}

function localizedExtensions() {
  return [
    EditorState.phrases.of(effectiveLocale.value === 'ru' ? CODEMIRROR_RU_PHRASES : {}),
    placeholder(translate(props.placeholder)),
    EditorView.contentAttributes.of({
      'aria-label': translate(props.label),
      spellcheck: 'true',
      autocorrect: 'on',
      autocapitalize: 'sentences',
      writingsuggestions: 'true',
    }),
  ];
}

function editorExtensions(editor: Pick<ManagedEditor, 'editableCompartment' | 'localizedCompartment'>) {
  return [
    history(),
    drawSelection(),
    ...markdownCodeHighlightingExtensions(),
    EditorView.lineWrapping,
    scrollPastEnd(),
    highlightActiveLine(),
    search({ top: true }),
    highlightSelectionMatches(),
    editor.editableCompartment.of(readonlyExtensions()),
    editor.localizedCompartment.of(localizedExtensions()),
    keymap.of([
      indentWithTab,
      ...defaultKeymap,
      ...historyKeymap,
      ...searchKeymap,
    ]),
    EditorView.updateListener.of((update) => {
      if (!update.docChanged || syncingFromProps) return;

      emit('clear-content-error');
      emit('update:content', update.state.doc.toString());
    }),
  ];
}

function createEditor(root: HTMLDivElement) {
  const editableCompartment = new Compartment();
  const localizedCompartment = new Compartment();
  const compartments = { editableCompartment, localizedCompartment };

  const view = new EditorView({
    state: EditorState.create({
      doc: String(props.content || ''),
      extensions: editorExtensions(compartments),
    }),
    parent: root,
  });

  return {
    view,
    editableCompartment,
    localizedCompartment,
  };
}

function replaceManagedEditorContent(editor: ManagedEditor | null, value: string) {
  const view = editor?.view;
  if (!view) return;
  const next = String(value || '');
  const current = view.state.doc.toString();
  if (next === current) return;

  syncingFromProps = true;
  try {
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: next },
      annotations: Transaction.addToHistory.of(false),
    });
  } finally {
    syncingFromProps = false;
  }
}

function replaceEditorContent(value: string) {
  replaceManagedEditorContent(inlineEditor.value, value);
  replaceManagedEditorContent(fullscreenEditor.value, value);
}

function resetScroll() {
  for (const editor of [inlineEditor.value, fullscreenEditor.value]) {
    const view = editor?.view;
    if (!view) continue;
    view.scrollDOM.scrollTop = 0;
    view.scrollDOM.scrollLeft = 0;
  }
}

function focus() {
  (fullscreenOpen.value ? fullscreenEditor.value : inlineEditor.value)?.view.focus();
}

function reconfigureReadonly() {
  for (const editor of [inlineEditor.value, fullscreenEditor.value]) {
    editor?.view.dispatch({
      effects: editor.editableCompartment.reconfigure(readonlyExtensions()),
    });
  }
}

function reconfigureLocale() {
  for (const editor of [inlineEditor.value, fullscreenEditor.value]) {
    editor?.view.dispatch({
      effects: editor.localizedCompartment.reconfigure(localizedExtensions()),
    });
  }
}

function destroyFullscreenEditor() {
  fullscreenEditor.value?.view.destroy();
  fullscreenEditor.value = null;
}

function openFullscreen() {
  fullscreenOpen.value = true;
}

function closeFullscreen() {
  fullscreenOpen.value = false;
}

onMounted(() => {
  const root = editorRootRef.value;
  if (!root) return;

  inlineEditor.value = createEditor(root);
});

onBeforeUnmount(() => {
  inlineEditor.value?.view.destroy();
  inlineEditor.value = null;
  destroyFullscreenEditor();
});

watch(
  () => props.content,
  (value) => replaceEditorContent(value)
);

watch(
  () => props.readonly,
  () => reconfigureReadonly()
);

watch(
  effectiveLocale,
  () => reconfigureLocale()
);

watch(
  fullscreenOpen,
  async (open) => {
    if (!open) {
      destroyFullscreenEditor();
      return;
    }

    await nextTick();
    const root = fullscreenEditorRootRef.value;
    if (!root || fullscreenEditor.value) return;

    fullscreenEditor.value = createEditor(root);
    fullscreenEditor.value.view.focus();
  }
);

const exposed: KnowledgeBlockCodeEditorExpose = {
  resetScroll,
  focus,
};

defineExpose(exposed);
</script>

<style scoped>
.knowledge-block-code-field {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.knowledge-block-code-field__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.knowledge-block-code-field__label {
  color: var(--color-text-muted);
  font-size: 0.9rem;
}

.knowledge-block-content-editor__expand {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-height: 30px;
  padding: 4px 8px;
  color: var(--color-text);
  font-size: 0.85rem;
  line-height: 1.2;
  white-space: nowrap;
}

.knowledge-block-content-editor__expand :deep(.svg-icon) {
  color: var(--color-text-muted);
}

.knowledge-block-content-editor {
  position: relative;
  height: clamp(360px, calc(var(--app-vh, 1vh) * 68), 640px);
  border: 1px solid var(--color-border-strong);
  border-radius: 6px;
  background: var(--color-surface);
  overflow: hidden;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}

.knowledge-block-content-editor:focus-within {
  border-color: var(--color-focus);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--color-focus) 18%, transparent);
}

.knowledge-block-content-editor--error {
  border-color: var(--color-danger);
  box-shadow: 0 0 0 1px color-mix(in srgb, var(--color-danger) 22%, transparent);
}

.knowledge-block-content-editor--error:focus-within {
  border-color: var(--color-danger);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--color-danger) 18%, transparent);
}

.knowledge-block-content-editor--readonly {
  background: var(--color-surface-muted);
}

.knowledge-block-content-editor__host {
  height: 100%;
}

.knowledge-block-content-editor--fullscreen {
  height: 100%;
  min-height: 0;
}

.knowledge-block-content-editor__hint {
  margin-top: 0;
}

@media (max-width: 640px) {
  .knowledge-block-content-editor {
    height: clamp(180px, calc(var(--app-vh, 1vh) * 34), 280px);
    font-size: 1rem;
  }

  .knowledge-block-content-editor--fullscreen {
    height: 100%;
  }
}

:global(.modal-backdrop.knowledge-block-editor-modal-backdrop) {
  overflow: hidden;
  overscroll-behavior: none;
}

:global(.modal.knowledge-block-editor-modal) {
  width: min(1120px, 96vw);
  height: min(900px, calc(var(--app-vh, 1vh) * 92));
  max-height: calc(var(--app-vh, 1vh) * 94);
  display: grid;
  grid-template-rows: auto minmax(0, 1fr);
  gap: 12px;
  min-height: 0;
  overflow: hidden !important;
  overscroll-behavior: none;
}

.knowledge-block-editor-modal__top {
  display: flex;
  flex-direction: column;
  gap: 8px;
  min-width: 0;
}

.knowledge-block-editor-modal__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  min-width: 0;
}

.knowledge-block-editor-modal__header h3 {
  margin: 0;
  min-width: 0;
  overflow: hidden;
  color: var(--color-text);
  font-size: 1rem;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.knowledge-block-editor-modal__actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex: 0 0 auto;
}

.knowledge-block-editor-modal__error {
  margin: 0;
}

.knowledge-block-content-editor--fullscreen :deep(.cm-editor) {
  min-height: 0;
}

.knowledge-block-content-editor--fullscreen :deep(.cm-scroller) {
  overflow: auto;
  touch-action: pan-y;
}

@media (max-width: 720px) {
  :global(.modal-backdrop.knowledge-block-editor-modal-backdrop) {
    align-items: stretch;
    justify-content: stretch;
    padding: 0;
    background: var(--color-bg);
  }

  :global(.modal.knowledge-block-editor-modal) {
    width: 100%;
    height: calc(var(--app-vh, 1vh) * 100);
    height: 100dvh;
    max-height: calc(var(--app-vh, 1vh) * 100);
    max-height: 100dvh;
    border: none;
    border-radius: 0;
    box-shadow: none;
    padding:
      calc(10px + var(--app-safe-area-top))
      calc(10px + var(--app-safe-area-right))
      calc(10px + var(--app-safe-area-bottom))
      calc(10px + var(--app-safe-area-left));
  }
}

:deep(.cm-editor) {
  height: 100%;
  background: var(--color-surface);
  color: var(--color-text);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.95rem;
}

:deep(.cm-editor.cm-focused) {
  outline: none;
}

:deep(.cm-scroller) {
  font-family: inherit;
  line-height: 1.5;
  overscroll-behavior: contain;
}

:deep(.cm-content) {
  min-height: 100%;
  padding: 6px 0;
  caret-color: var(--color-text);
}

:deep(.cm-line) {
  padding: 0 8px;
}

:deep(.cm-activeLine) {
  background: color-mix(in srgb, var(--color-focus) 8%, transparent);
}

:deep(.cm-selectionBackground),
:deep(.cm-focused .cm-selectionBackground),
:deep(.cm-content ::selection) {
  background: color-mix(in srgb, var(--color-focus) 25%, transparent);
}

:deep(.cm-cursor) {
  border-left-color: var(--color-text);
}

:deep(.cm-placeholder) {
  color: var(--color-text-subtle);
}

:deep(.cm-line.markdown-code-editor__comment-line),
:deep(.cm-line.markdown-code-editor__comment-line *) {
  color: var(--color-text-subtle) !important;
}

:deep(.cm-line.markdown-code-editor__heading-line),
:deep(.cm-line.markdown-code-editor__heading-line *) {
  color: var(--color-link) !important;
  font-style: normal !important;
  font-weight: 400 !important;
  text-decoration: none !important;
}

:deep(.cm-line.markdown-code-editor__heading-line--strong),
:deep(.cm-line.markdown-code-editor__heading-line--strong *) {
  font-weight: 700 !important;
}

:deep(.cm-line.markdown-code-editor__heading-line--emphasis),
:deep(.cm-line.markdown-code-editor__heading-line--emphasis *) {
  font-style: italic !important;
}

:deep(.cm-panels) {
  border-color: var(--color-border-strong);
  background: var(--color-surface-muted);
  color: var(--color-text);
}

:deep(.cm-panels-top) {
  border-bottom: 1px solid var(--color-border-strong);
}

:deep(.cm-panel.cm-search) {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px;
  padding: 8px;
}

:deep(.cm-panel.cm-search input),
:deep(.cm-panel.cm-search button) {
  font: inherit;
}

:deep(.cm-panel.cm-search input) {
  min-height: 30px;
  border: 1px solid var(--color-border-strong);
  border-radius: 6px;
  background: var(--color-surface);
  color: var(--color-text);
  padding: 4px 8px;
}

:deep(.cm-panel.cm-search button) {
  min-height: 30px;
  border: 1px solid var(--color-border-strong);
  border-radius: 6px;
  background: var(--color-surface);
  color: var(--color-text);
  padding: 4px 8px;
}

:deep(.cm-panel.cm-search button:hover) {
  background: var(--color-surface-hover);
}

:deep(.cm-searchMatch) {
  background: color-mix(in srgb, var(--color-warning-bg) 80%, var(--color-focus) 18%);
}

:deep(.cm-searchMatch-selected) {
  background: color-mix(in srgb, var(--color-focus) 38%, transparent);
}

:deep(.cm-tooltip) {
  border-color: var(--color-border-strong);
  background: var(--color-surface-elevated);
  color: var(--color-text);
  box-shadow: var(--shadow-menu);
}

.knowledge-block-content-editor--readonly :deep(.cm-editor) {
  background: var(--color-surface-muted);
}
</style>
