<template>
  <div class="stack">
    <label>
      Content
      <div
        :class="[
          'knowledge-block-content-editor',
          contentError && 'knowledge-block-content-editor--error',
        ]"
      >
        <pre class="knowledge-block-content-editor__mirror" aria-hidden="true"><code
          :style="contentMirrorStyle"
          v-html="contentHighlightHtml"
        ></code></pre>
        <textarea
          ref="contentTextareaRef"
          :value="content"
          :class="[
            'full',
            'knowledge-block-content-editor__textarea',
            !content && 'knowledge-block-content-editor__textarea--empty',
          ]"
          placeholder="Write the knowledge block content..."
          spellcheck="false"
          @input="handleContentEditorInput"
          @scroll="syncContentEditorScroll"
        ></textarea>
      </div>
      <div class="muted knowledge-block-content-editor__hint">
        Lines starting with <code>//// </code> are treated as comments and removed from the compiled prompt.
      </div>
      <div v-if="contentError" class="error-text">{{ contentError }}</div>
    </label>
  </div>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue';

import { COMMENT_PREFIX } from '@/features/catalogs/model/knowledgeBlockMarkdownBlocks';

const props = defineProps<{
  content: string;
  contentError: string | null;
}>();

const emit = defineEmits<{
  (e: 'update:content', value: string): void;
  (e: 'clear-content-error'): void;
}>();

const contentTextareaRef = ref<HTMLTextAreaElement | null>(null);
const contentScrollTop = ref(0);
const contentScrollLeft = ref(0);

function escapeHtml(value: string) {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

const markdownHeadingPattern = /^ {0,3}(#{1,6})(?:\s|$)/;

function contentLineClass(line: string) {
  if (line.startsWith(COMMENT_PREFIX)) return 'knowledge-block-content-editor__comment';

  const heading = line.match(markdownHeadingPattern);
  if (!heading) return 'knowledge-block-content-editor__plain';

  const level = heading[1].length;
  if (level <= 2) {
    return 'knowledge-block-content-editor__heading knowledge-block-content-editor__heading--strong';
  }

  if (level === 3) return 'knowledge-block-content-editor__heading';

  return 'knowledge-block-content-editor__heading knowledge-block-content-editor__heading--emphasis';
}

const contentHighlightHtml = computed(() => {
  const text = String(props.content || '');
  if (text === '') return '&nbsp;';

  const highlighted = text
    .split('\n')
    .map((line) => {
      const escaped = escapeHtml(line) || '&nbsp;';
      const className = contentLineClass(line);
      return `<span class="${className}">${escaped}</span>`;
    })
    .join('\n');

  return text.endsWith('\n') ? `${highlighted}\n&nbsp;` : highlighted;
});

const contentMirrorStyle = computed(() => ({
  transform: `translate(${-contentScrollLeft.value}px, ${-contentScrollTop.value}px)`,
}));

function syncContentEditorScroll(event: Event) {
  const target = event.target as HTMLTextAreaElement | null;
  if (!target) return;
  syncContentEditorScrollFromTextarea(target);
}

function handleContentEditorInput(event: Event) {
  emit('clear-content-error');

  const target = event.target as HTMLTextAreaElement | null;
  if (!target) return;

  emit('update:content', target.value);
  syncContentEditorScroll(event);
}

function syncContentEditorScrollFromTextarea(textarea: HTMLTextAreaElement) {
  contentScrollTop.value = textarea.scrollTop;
  contentScrollLeft.value = textarea.scrollLeft;
}

function resetScroll() {
  contentScrollTop.value = 0;
  contentScrollLeft.value = 0;
  const textarea = contentTextareaRef.value;
  if (!textarea) return;
  textarea.scrollTop = 0;
  textarea.scrollLeft = 0;
  syncContentEditorScrollFromTextarea(textarea);
}

defineExpose({
  resetScroll,
});
</script>

<style scoped>
.knowledge-block-content-editor {
  position: relative;
  height: clamp(360px, calc(var(--app-vh, 1vh) * 68), 640px);
  border: 1px solid var(--color-border-strong);
  border-radius: 6px;
  background: var(--color-surface);
  overflow: hidden;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}

.knowledge-block-content-editor--error {
  border-color: var(--color-danger);
  box-shadow: 0 0 0 1px color-mix(in srgb, var(--color-danger) 22%, transparent);
}

.knowledge-block-content-editor__mirror {
  position: absolute;
  inset: 0;
  margin: 0;
  pointer-events: none;
  overflow: hidden;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  z-index: 2;
}

.knowledge-block-content-editor__mirror code {
  display: block;
  min-height: 100%;
  padding: 6px 8px;
  font: inherit;
  line-height: 1.5;
  white-space: inherit;
  overflow-wrap: inherit;
}

.knowledge-block-content-editor__textarea {
  display: block;
  position: relative;
  z-index: 1;
  border: 0;
  border-radius: 0;
  background: transparent;
  color: transparent;
  text-shadow: 0 0 0 var(--color-text);
  caret-color: var(--color-text);
  -webkit-text-fill-color: transparent;
  height: 100%;
  min-height: 0;
  max-height: 100%;
  overflow: auto;
  overflow-anchor: none;
  overscroll-behavior: contain;
  resize: none;
  line-height: 1.5;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}

.knowledge-block-content-editor__textarea:focus {
  outline: none;
  box-shadow: none;
}

.knowledge-block-content-editor__textarea--empty {
  text-shadow: none;
  color: inherit;
  -webkit-text-fill-color: inherit;
}

.knowledge-block-content-editor__textarea::placeholder {
  color: var(--color-text-subtle);
  -webkit-text-fill-color: var(--color-text-subtle);
}

.knowledge-block-content-editor__hint {
  margin-top: 6px;
}

@media (max-width: 640px) {
  .knowledge-block-content-editor {
    font-size: 1rem;
  }
}

:deep(.knowledge-block-content-editor__comment) {
  color: var(--color-text-subtle);
}

:deep(.knowledge-block-content-editor__heading) {
  color: var(--color-link);
}

:deep(.knowledge-block-content-editor__heading--strong) {
  font-weight: 700;
}

:deep(.knowledge-block-content-editor__heading--emphasis) {
  font-style: italic;
}

:deep(.knowledge-block-content-editor__plain) {
  color: transparent;
}
</style>
