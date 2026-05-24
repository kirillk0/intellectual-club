import { watch } from 'vue';
import { canTranslate, effectiveLocale, translate, translateMultiline, translationVariants } from './index';

const TRANSLATED_ATTRIBUTES = ['aria-label', 'title', 'placeholder', 'alt'] as const;
const textOriginals = new WeakMap<Text, string>();
const attributeOriginals = new WeakMap<Element, Map<string, string>>();

let observer: MutationObserver | null = null;
let scheduled = false;

const ignoredTextSelector = [
  'script',
  'style',
  'pre',
  'code',
  'textarea',
  '[data-i18n-ignore]',
  '.chat-markdown',
  '.json-tree',
  '.token',
  '.chat-list-row__title',
  '.catalog-row__title',
  '.kb-list-item__title',
  '.tool-binding-list-item__name',
].join(',');

const ignoredAttributeSelector = [
  'script',
  'style',
  'pre',
  'code',
  '[data-i18n-ignore]',
  '.chat-markdown',
  '.json-tree',
  '.token',
  '.chat-list-row__title',
  '.catalog-row__title',
  '.kb-list-item__title',
  '.tool-binding-list-item__name',
].join(',');

const splitTrim = (value: string) => {
  const leading = value.match(/^\s*/u)?.[0] ?? '';
  const trailing = value.match(/\s*$/u)?.[0] ?? '';
  const core = value.slice(leading.length, value.length - trailing.length);
  return { leading, core, trailing };
};

const shouldTranslateCore = (value: string) => /[A-Za-z]/u.test(value) && canTranslate(value);

const translateTextNode = (node: Text) => {
  const parent = node.parentElement;
  if (!parent || parent.closest(ignoredTextSelector)) return;

  const { leading, core, trailing } = splitTrim(node.data);
  if (!core) return;

  const previousOriginal = textOriginals.get(node);
  const original = previousOriginal && translationVariants(previousOriginal).includes(core)
    ? previousOriginal
    : shouldTranslateCore(core)
      ? core
      : null;

  if (!original) return;
  textOriginals.set(node, original);

  const next = `${leading}${translate(original)}${trailing}`;
  if (node.data !== next) node.data = next;
};

const translateAttributes = (element: Element) => {
  if (element.closest(ignoredAttributeSelector)) return;

  for (const attr of TRANSLATED_ATTRIBUTES) {
    const current = element.getAttribute(attr);
    if (!current) continue;

    let originals = attributeOriginals.get(element);
    if (!originals) {
      originals = new Map();
      attributeOriginals.set(element, originals);
    }

    const previousOriginal = originals.get(attr);
    const original = previousOriginal && translationVariants(previousOriginal).includes(current)
      ? previousOriginal
      : shouldTranslateCore(current)
        ? current
        : null;

    if (!original) continue;
    originals.set(attr, original);

    const next = translate(original);
    if (current !== next) element.setAttribute(attr, next);
  }
};

const walk = (root: Node) => {
  if (root.nodeType === Node.TEXT_NODE) {
    translateTextNode(root as Text);
    return;
  }

  if (root.nodeType !== Node.ELEMENT_NODE && root.nodeType !== Node.DOCUMENT_FRAGMENT_NODE) return;

  if (root instanceof Element) {
    translateAttributes(root);
    if (root.closest(ignoredTextSelector)) return;
  }

  const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
  let node: Node | null = walker.nextNode();

  while (node) {
    if (node.nodeType === Node.TEXT_NODE) {
      translateTextNode(node as Text);
    } else if (node instanceof Element) {
      translateAttributes(node);
    }

    node = walker.nextNode();
  }
};

const scheduleWalk = (root: HTMLElement) => {
  if (scheduled) return;
  scheduled = true;
  window.requestAnimationFrame(() => {
    scheduled = false;
    walk(root);
  });
};

const patchBrowserDialogs = () => {
  const nativeAlert = window.alert.bind(window);
  const nativeConfirm = window.confirm.bind(window);

  window.alert = (message?: unknown) => nativeAlert(translateMultiline(String(message ?? '')));
  window.confirm = (message?: unknown) => nativeConfirm(translateMultiline(String(message ?? '')));
};

export const installDomTranslations = (root: HTMLElement) => {
  if (typeof window === 'undefined' || typeof MutationObserver === 'undefined') return;

  patchBrowserDialogs();
  walk(root);

  observer?.disconnect();
  observer = new MutationObserver((mutations) => {
    if (mutations.some((mutation) => mutation.type === 'childList' || mutation.type === 'attributes')) {
      scheduleWalk(root);
    }
  });

  observer.observe(root, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: [...TRANSLATED_ATTRIBUTES],
  });

  watch(effectiveLocale, () => scheduleWalk(root));
};
