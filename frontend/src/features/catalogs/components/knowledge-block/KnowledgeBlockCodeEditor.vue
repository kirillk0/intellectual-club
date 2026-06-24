<template>
  <div class="stack">
    <div class="knowledge-block-code-field">
      <div class="knowledge-block-code-field__label">Content</div>
      <div
        :class="[
          'knowledge-block-content-editor',
          contentError && 'knowledge-block-content-editor--error',
          readonly && 'knowledge-block-content-editor--readonly',
        ]"
      >
        <div ref="editorRootRef" class="knowledge-block-content-editor__host" data-i18n-ignore></div>
      </div>
      <div class="muted knowledge-block-content-editor__hint">
        Lines starting with <code>//// </code> are treated as comments and removed from the compiled prompt.
      </div>
      <div v-if="contentError" class="error-text">{{ contentError }}</div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { markdown } from '@codemirror/lang-markdown';
import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
} from '@codemirror/commands';
import {
  Compartment,
  EditorState,
  RangeSetBuilder,
  Transaction,
} from '@codemirror/state';
import {
  Decoration,
  EditorView,
  drawSelection,
  highlightActiveLine,
  keymap,
  placeholder,
  ViewPlugin,
  type DecorationSet,
  type ViewUpdate,
} from '@codemirror/view';
import {
  defaultHighlightStyle,
  syntaxHighlighting,
} from '@codemirror/language';
import {
  highlightSelectionMatches,
  search,
  searchKeymap,
} from '@codemirror/search';
import { onBeforeUnmount, onMounted, ref, watch } from 'vue';

import { effectiveLocale, translate } from '@/i18n';
import { COMMENT_PREFIX } from '@/features/catalogs/model/knowledgeBlockMarkdownBlocks';
import { CODEMIRROR_RU_PHRASES } from '../codeMirrorPhrases';
import type { KnowledgeBlockCodeEditorExpose } from './types';

const props = defineProps<{
  content: string;
  contentError: string | null;
  readonly: boolean;
}>();

const emit = defineEmits<{
  (e: 'update:content', value: string): void;
  (e: 'clear-content-error'): void;
}>();

const markdownHeadingPattern = /^ {0,3}(#{1,6})(?:\s|$)/;
const editableCompartment = new Compartment();
const localizedCompartment = new Compartment();
const editorRootRef = ref<HTMLDivElement | null>(null);
const editorView = ref<EditorView | null>(null);
let syncingFromProps = false;

const commentLineDecoration = Decoration.line({
  class: 'knowledge-block-content-editor__comment-line',
});
const headingLineDecoration = Decoration.line({
  class: 'knowledge-block-content-editor__heading-line',
});
const strongHeadingLineDecoration = Decoration.line({
  class: 'knowledge-block-content-editor__heading-line knowledge-block-content-editor__heading-line--strong',
});
const emphasisHeadingLineDecoration = Decoration.line({
  class: 'knowledge-block-content-editor__heading-line knowledge-block-content-editor__heading-line--emphasis',
});

function decorationForLine(text: string) {
  if (text.startsWith(COMMENT_PREFIX)) return commentLineDecoration;

  const heading = text.match(markdownHeadingPattern);
  if (!heading) return null;

  const level = heading[1].length;
  if (level <= 2) return strongHeadingLineDecoration;
  if (level === 3) return headingLineDecoration;
  return emphasisHeadingLineDecoration;
}

function buildLineDecorations(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();

  for (const range of view.visibleRanges) {
    let line = view.state.doc.lineAt(range.from);

    while (line.from <= range.to) {
      const decoration = decorationForLine(line.text);
      if (decoration) builder.add(line.from, line.from, decoration);
      if (line.to >= range.to) break;
      line = view.state.doc.lineAt(line.to + 1);
    }
  }

  return builder.finish();
}

const knowledgeBlockLineDecorations = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;

    constructor(view: EditorView) {
      this.decorations = buildLineDecorations(view);
    }

    update(update: ViewUpdate) {
      if (!update.docChanged && !update.viewportChanged) return;
      this.decorations = buildLineDecorations(update.view);
    }
  },
  {
    decorations: (plugin) => plugin.decorations,
  }
);

function readonlyExtensions() {
  return [
    EditorState.readOnly.of(props.readonly),
    EditorView.editable.of(!props.readonly),
  ];
}

function localizedExtensions() {
  return [
    EditorState.phrases.of(effectiveLocale.value === 'ru' ? CODEMIRROR_RU_PHRASES : {}),
    placeholder(translate('Write the knowledge block content...')),
    EditorView.contentAttributes.of({
      'aria-label': translate('Content'),
      spellcheck: 'true',
      autocorrect: 'on',
      autocapitalize: 'sentences',
      writingsuggestions: 'true',
    }),
  ];
}

function editorExtensions() {
  return [
    history(),
    drawSelection(),
    syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
    markdown(),
    EditorView.lineWrapping,
    highlightActiveLine(),
    search({ top: true }),
    highlightSelectionMatches(),
    knowledgeBlockLineDecorations,
    editableCompartment.of(readonlyExtensions()),
    localizedCompartment.of(localizedExtensions()),
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

function replaceEditorContent(value: string) {
  const view = editorView.value;
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

function resetScroll() {
  const view = editorView.value;
  if (!view) return;

  view.scrollDOM.scrollTop = 0;
  view.scrollDOM.scrollLeft = 0;
}

function focus() {
  editorView.value?.focus();
}

onMounted(() => {
  const root = editorRootRef.value;
  if (!root) return;

  editorView.value = new EditorView({
    state: EditorState.create({
      doc: String(props.content || ''),
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
  () => props.content,
  (value) => replaceEditorContent(value)
);

watch(
  () => props.readonly,
  () => {
    editorView.value?.dispatch({
      effects: editableCompartment.reconfigure(readonlyExtensions()),
    });
  }
);

watch(
  effectiveLocale,
  () => {
    editorView.value?.dispatch({
      effects: localizedCompartment.reconfigure(localizedExtensions()),
    });
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

.knowledge-block-code-field__label {
  color: var(--color-text-muted);
  font-size: 0.9rem;
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

.knowledge-block-content-editor__hint {
  margin-top: 0;
}

@media (max-width: 640px) {
  .knowledge-block-content-editor {
    font-size: 1rem;
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

:deep(.cm-line.knowledge-block-content-editor__comment-line),
:deep(.cm-line.knowledge-block-content-editor__comment-line *) {
  color: var(--color-text-subtle) !important;
}

:deep(.cm-line.knowledge-block-content-editor__heading-line),
:deep(.cm-line.knowledge-block-content-editor__heading-line *) {
  color: var(--color-link) !important;
  font-style: normal !important;
  font-weight: 400 !important;
  text-decoration: none !important;
}

:deep(.cm-line.knowledge-block-content-editor__heading-line--strong),
:deep(.cm-line.knowledge-block-content-editor__heading-line--strong *) {
  font-weight: 700 !important;
}

:deep(.cm-line.knowledge-block-content-editor__heading-line--emphasis),
:deep(.cm-line.knowledge-block-content-editor__heading-line--emphasis *) {
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
