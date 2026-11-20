<template>
  <iframe
    ref="frame"
    class="docx-preview"
    :title="title"
    sandbox="allow-same-origin"
    referrerpolicy="no-referrer"
    :srcdoc="frameDocument"
    @load="render"
  ></iframe>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { renderAsync, type Options } from 'docx-preview';

const props = defineProps<{ file: Blob; title: string }>();
const emit = defineEmits<{ ready: []; error: [] }>();
const frame = ref<HTMLIFrameElement | null>(null);
const frameDocument = `<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; base-uri 'none'; form-action 'none'">
<style>body { margin: 0; }</style></head><body></body></html>`;

// The default factory creates elements in the application document, even when
// the target container is in a different frame. Create them under its CSP instead.
const htmlTags = new Set('article br col colgroup del div footer header img ins li ol p section span style sub sup table td tr wbr'.split(' '));
const svgTags = new Set('svg rect ellipse line g foreignObject image'.split(' '));
const mathTags = new Set('math mfrac mn mo mover mroot mrow ms msqrt msub msubsup msup mtable mtd mtr munder munderover'.split(' '));

function frameNodeFactory(doc: Document): Options['h'] {
  const make: Options['h'] = (value) => {
    if (typeof value === 'string') return doc.createTextNode(value);
    if (value instanceof Node || value instanceof doc.defaultView!.Node) return value;
    const { ns, tagName, className, style, children } = value;
    if (tagName === '#comment') return doc.createComment('');
    if (tagName === '#fragment') {
      const fragment = doc.createDocumentFragment();
      children?.forEach(child => fragment.appendChild(make(child)));
      return fragment;
    }

    // Only passive document elements and presentational attributes are needed.
    // In particular, show hyperlink text without making it navigable.
    const tags = ns === 'http://www.w3.org/2000/svg' ? svgTags
      : ns === 'http://www.w3.org/1998/Math/MathML' ? mathTags : htmlTags;
    const el = tags.has(tagName) ? (ns ? doc.createElementNS(ns, tagName) : doc.createElement(tagName))
      : doc.createElement('span');
    if (className) el.setAttribute('class', className);
    if (typeof style === 'string') el.setAttribute('style', style);
    else if (style) Object.assign((el as HTMLElement).style, style);
    for (const attr of ['colSpan', 'lang']) {
      if (value[attr] != null) el.setAttribute(attr.toLowerCase(), String(value[attr]));
    }
    children?.forEach(child => { if (child != null) el.appendChild(make(child)); });
    return el;
  };
  return make;
}

let started = false;
async function render() {
  const doc = frame.value?.contentDocument;
  if (!doc || !doc.querySelector('meta[http-equiv="Content-Security-Policy"]') || started) return;
  started = true;
  try {
    await renderAsync(props.file, doc.body, undefined, {
      h: frameNodeFactory(doc), renderAltChunks: false, useBase64URL: true,
    });
    if (frame.value) emit('ready');
  } catch {
    if (frame.value) emit('error');
  }
}
</script>

<style scoped>
.docx-preview {
  display: block;
  width: 100%;
  height: min(70vh, 720px);
  box-sizing: border-box;
  border: 1px solid var(--color-border-strong);
  border-radius: 12px;
  background: white;
}

.attachment-preview-content--fullscreen .docx-preview {
  height: 100dvh;
  border: 0;
  border-radius: 0;
}
</style>
