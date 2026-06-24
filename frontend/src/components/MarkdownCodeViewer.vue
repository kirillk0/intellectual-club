<template>
  <div class="markdown-code-viewer">
    <div ref="editorRootRef" class="markdown-code-viewer__host" data-i18n-ignore></div>
  </div>
</template>

<script setup lang="ts">
import { defaultKeymap } from '@codemirror/commands';
import { highlightSelectionMatches, search, searchKeymap } from '@codemirror/search';
import {
  Compartment,
  EditorState,
  Transaction,
} from '@codemirror/state';
import {
  drawSelection,
  EditorView,
  highlightActiveLine,
  keymap,
} from '@codemirror/view';
import { onBeforeUnmount, onMounted, ref, watch } from 'vue';

import { effectiveLocale, translate } from '@/i18n';
import { CODEMIRROR_RU_PHRASES } from '@/utils/codeMirrorPhrases';
import { markdownCodeHighlightingExtensions } from '@/utils/markdownCodeMirror';

const props = defineProps<{
  value: string;
  label: string;
}>();

const localizedCompartment = new Compartment();
const editorRootRef = ref<HTMLDivElement | null>(null);
const editorView = ref<EditorView | null>(null);

function localizedExtensions() {
  return [
    EditorState.phrases.of(effectiveLocale.value === 'ru' ? CODEMIRROR_RU_PHRASES : {}),
    EditorView.contentAttributes.of({
      'aria-label': translate(props.label),
      spellcheck: 'false',
    }),
  ];
}

function editorExtensions() {
  return [
    EditorState.readOnly.of(true),
    EditorView.editable.of(false),
    drawSelection(),
    ...markdownCodeHighlightingExtensions(),
    EditorView.lineWrapping,
    highlightActiveLine(),
    search({ top: true }),
    highlightSelectionMatches(),
    localizedCompartment.of(localizedExtensions()),
    keymap.of([
      ...defaultKeymap,
      ...searchKeymap,
    ]),
  ];
}

function replaceEditorContent(value: string) {
  const view = editorView.value;
  if (!view) return;

  const next = String(value || '');
  const current = view.state.doc.toString();
  if (next === current) return;

  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: next },
    annotations: Transaction.addToHistory.of(false),
  });
}

onMounted(() => {
  const root = editorRootRef.value;
  if (!root) return;

  editorView.value = new EditorView({
    state: EditorState.create({
      doc: String(props.value || ''),
      extensions: editorExtensions(),
    }),
    parent: root,
  });
});

onBeforeUnmount(() => {
  editorView.value?.destroy();
  editorView.value = null;
});

watch(
  () => props.value,
  (value) => replaceEditorContent(value)
);

watch(
  [effectiveLocale, () => props.label],
  () => {
    editorView.value?.dispatch({
      effects: localizedCompartment.reconfigure(localizedExtensions()),
    });
  }
);
</script>

<style scoped>
.markdown-code-viewer {
  position: relative;
  height: clamp(280px, calc(var(--app-vh, 1vh) * 60), 620px);
  border: 1px solid var(--color-border-strong);
  border-radius: 6px;
  background: var(--color-surface-muted);
  overflow: hidden;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}

.markdown-code-viewer:focus-within {
  border-color: var(--color-focus);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--color-focus) 18%, transparent);
}

.markdown-code-viewer__host {
  height: 100%;
}

@media (max-width: 640px) {
  .markdown-code-viewer {
    height: clamp(240px, calc(var(--app-vh, 1vh) * 58), 520px);
    font-size: 1rem;
  }
}

:deep(.cm-editor) {
  height: 100%;
  background: var(--color-surface-muted);
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
</style>
