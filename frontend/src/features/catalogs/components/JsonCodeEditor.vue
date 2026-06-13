<template>
  <div
    :class="[
      'json-code-editor',
      error && 'json-code-editor--error',
      readonly && 'json-code-editor--readonly',
    ]"
  >
    <div ref="editorRootRef" class="json-code-editor__host" data-i18n-ignore></div>
  </div>
</template>

<script setup lang="ts">
import { json } from '@codemirror/lang-json';
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
  StateField,
  Transaction,
} from '@codemirror/state';
import {
  Decoration,
  EditorView,
  drawSelection,
  highlightActiveLine,
  keymap,
  lineNumbers,
  placeholder,
  type DecorationSet,
} from '@codemirror/view';
import {
  bracketMatching,
  defaultHighlightStyle,
  foldGutter,
  foldKeymap,
  indentOnInput,
  indentUnit,
  syntaxHighlighting,
} from '@codemirror/language';
import {
  highlightSelectionMatches,
  search,
  searchKeymap,
} from '@codemirror/search';
import { onBeforeUnmount, onMounted, ref, watch } from 'vue';

import { effectiveLocale, translate } from '@/i18n';
import { CODEMIRROR_RU_PHRASES } from './codeMirrorPhrases';

const props = withDefaults(
  defineProps<{
    modelValue: string;
    error?: string | null;
    readonly?: boolean;
    label: string;
    placeholder?: string;
  }>(),
  {
    error: null,
    readonly: false,
    placeholder: '',
  }
);

const emit = defineEmits<{
  (e: 'update:modelValue', value: string): void;
}>();

const editableCompartment = new Compartment();
const localizedCompartment = new Compartment();
const editorRootRef = ref<HTMLDivElement | null>(null);
const editorView = ref<EditorView | null>(null);
let syncingFromProps = false;

const booleanTokenDecoration = Decoration.mark({
  class: 'json-code-editor__boolean-token',
});

function isLiteralBoundary(text: string, index: number) {
  if (index < 0 || index >= text.length) return true;
  return !/[A-Za-z0-9_$]/.test(text[index]);
}

function booleanTokenRanges(text: string) {
  const ranges: Array<{ from: number; to: number }> = [];
  let inString = false;
  let escaped = false;

  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char === '\\') {
        escaped = true;
      } else if (char === '"') {
        inString = false;
      }
      continue;
    }

    if (char === '"') {
      inString = true;
      continue;
    }

    for (const literal of ['true', 'false']) {
      if (!text.startsWith(literal, index)) continue;
      const to = index + literal.length;
      if (!isLiteralBoundary(text, index - 1) || !isLiteralBoundary(text, to)) continue;

      ranges.push({ from: index, to });
      index = to - 1;
      break;
    }
  }

  return ranges;
}

function buildBooleanTokenDecorations(state: EditorState): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();

  for (let lineNumber = 1; lineNumber <= state.doc.lines; lineNumber += 1) {
    const line = state.doc.line(lineNumber);
    for (const tokenRange of booleanTokenRanges(line.text)) {
      builder.add(line.from + tokenRange.from, line.from + tokenRange.to, booleanTokenDecoration);
    }
  }

  return builder.finish();
}

const jsonBooleanTokenDecorations = StateField.define<DecorationSet>({
  create(state) {
    return buildBooleanTokenDecorations(state);
  },
  update(decorations, transaction) {
    return transaction.docChanged ? buildBooleanTokenDecorations(transaction.state) : decorations;
  },
  provide: (field) => EditorView.decorations.from(field),
});

function readonlyExtensions() {
  return [
    EditorState.readOnly.of(Boolean(props.readonly)),
    EditorView.editable.of(!props.readonly),
  ];
}

function localizedExtensions() {
  return [
    EditorState.phrases.of(effectiveLocale.value === 'ru' ? CODEMIRROR_RU_PHRASES : {}),
    ...(props.placeholder ? [placeholder(translate(props.placeholder))] : []),
    EditorView.contentAttributes.of({
      'aria-label': translate(props.label),
      spellcheck: 'false',
    }),
  ];
}

function editorExtensions() {
  return [
    history(),
    drawSelection(),
    lineNumbers(),
    foldGutter(),
    syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
    json(),
    indentUnit.of('  '),
    indentOnInput(),
    bracketMatching(),
    EditorView.lineWrapping,
    highlightActiveLine(),
    search({ top: true }),
    highlightSelectionMatches(),
    jsonBooleanTokenDecorations,
    editableCompartment.of(readonlyExtensions()),
    localizedCompartment.of(localizedExtensions()),
    keymap.of([
      indentWithTab,
      ...defaultKeymap,
      ...historyKeymap,
      ...foldKeymap,
      ...searchKeymap,
    ]),
    EditorView.updateListener.of((update) => {
      if (!update.docChanged || syncingFromProps) return;

      emit('update:modelValue', update.state.doc.toString());
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

onMounted(() => {
  const root = editorRootRef.value;
  if (!root) return;

  editorView.value = new EditorView({
    state: EditorState.create({
      doc: String(props.modelValue || ''),
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
  () => props.modelValue,
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
  [effectiveLocale, () => props.label, () => props.placeholder],
  () => {
    editorView.value?.dispatch({
      effects: localizedCompartment.reconfigure(localizedExtensions()),
    });
  }
);
</script>

<style scoped>
.json-code-editor {
  position: relative;
  height: clamp(260px, calc(var(--app-vh, 1vh) * 45), 520px);
  border: 1px solid var(--color-border-strong);
  border-radius: 6px;
  background: var(--color-surface);
  overflow: hidden;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}

.json-code-editor:focus-within {
  border-color: var(--color-focus);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--color-focus) 18%, transparent);
}

.json-code-editor--error {
  border-color: var(--color-danger);
  box-shadow: 0 0 0 1px color-mix(in srgb, var(--color-danger) 22%, transparent);
}

.json-code-editor--error:focus-within {
  border-color: var(--color-danger);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--color-danger) 18%, transparent);
}

.json-code-editor--readonly {
  background: var(--color-surface-muted);
}

.json-code-editor__host {
  height: 100%;
}

@media (max-width: 640px) {
  .json-code-editor {
    height: clamp(240px, calc(var(--app-vh, 1vh) * 42), 420px);
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

:deep(.cm-gutters) {
  border-right: 1px solid var(--color-border);
  background: var(--color-surface-muted);
  color: var(--color-text-subtle);
}

:deep(.cm-lineNumbers .cm-gutterElement) {
  min-width: 34px;
  padding: 0 8px 0 6px;
}

:deep(.cm-foldGutter .cm-gutterElement) {
  min-width: 18px;
  padding: 0 4px;
  cursor: pointer;
}

:deep(.cm-activeLine),
:deep(.cm-activeLineGutter) {
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

:deep(.json-code-editor__boolean-token),
:deep(.json-code-editor__boolean-token *) {
  color: var(--color-success-text) !important;
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

.json-code-editor--readonly :deep(.cm-editor) {
  background: var(--color-surface-muted);
}
</style>
