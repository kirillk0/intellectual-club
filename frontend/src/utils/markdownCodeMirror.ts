import { markdown } from '@codemirror/lang-markdown';
import { defaultHighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { RangeSetBuilder } from '@codemirror/state';
import {
  Decoration,
  type DecorationSet,
  type EditorView,
  ViewPlugin,
  type ViewUpdate,
} from '@codemirror/view';

import { PROMPT_COMMENT_PREFIX } from '@/utils/promptMarkdown';

export const MARKDOWN_CODE_COMMENT_LINE_CLASS = 'markdown-code-editor__comment-line';
export const MARKDOWN_CODE_HEADING_LINE_CLASS = 'markdown-code-editor__heading-line';
export const MARKDOWN_CODE_HEADING_STRONG_LINE_CLASS = 'markdown-code-editor__heading-line--strong';
export const MARKDOWN_CODE_HEADING_EMPHASIS_LINE_CLASS = 'markdown-code-editor__heading-line--emphasis';

const markdownHeadingPattern = /^ {0,3}(#{1,6})(?:\s|$)/;

const commentLineDecoration = Decoration.line({
  class: MARKDOWN_CODE_COMMENT_LINE_CLASS,
});
const headingLineDecoration = Decoration.line({
  class: MARKDOWN_CODE_HEADING_LINE_CLASS,
});
const strongHeadingLineDecoration = Decoration.line({
  class: `${MARKDOWN_CODE_HEADING_LINE_CLASS} ${MARKDOWN_CODE_HEADING_STRONG_LINE_CLASS}`,
});
const emphasisHeadingLineDecoration = Decoration.line({
  class: `${MARKDOWN_CODE_HEADING_LINE_CLASS} ${MARKDOWN_CODE_HEADING_EMPHASIS_LINE_CLASS}`,
});

function decorationForLine(text: string) {
  if (text.startsWith(PROMPT_COMMENT_PREFIX)) return commentLineDecoration;

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

export const markdownCodeLineDecorations = ViewPlugin.fromClass(
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

export function markdownCodeHighlightingExtensions() {
  return [
    syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
    markdown(),
    markdownCodeLineDecorations,
  ];
}
