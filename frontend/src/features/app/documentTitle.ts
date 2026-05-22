import { computed, onBeforeUnmount, readonly, ref, toValue, watch, type MaybeRefOrGetter } from 'vue';

export const APP_DOCUMENT_TITLE = 'Intellectual Club';

const pageTitleOverrideRef = ref<string | null>(null);

const normalizeTitlePart = (value: unknown) => String(value || '').trim();

export const pageTitleOverride = readonly(pageTitleOverrideRef);

export function setPageTitleOverride(value: unknown) {
  pageTitleOverrideRef.value = normalizeTitlePart(value) || null;
}

export function clearPageTitleOverride() {
  pageTitleOverrideRef.value = null;
}

export function usePageTitleOverride(value: MaybeRefOrGetter<unknown>) {
  const stop = watch(
    () => normalizeTitlePart(toValue(value)) || null,
    (nextTitle) => {
      pageTitleOverrideRef.value = nextTitle;
    },
    { immediate: true }
  );

  onBeforeUnmount(() => {
    stop();
    clearPageTitleOverride();
  });
}

export function useDocumentTitle(pageTitle: MaybeRefOrGetter<unknown>) {
  const title = computed(() => {
    const titlePart = normalizeTitlePart(toValue(pageTitle));
    return titlePart ? `${titlePart} - ${APP_DOCUMENT_TITLE}` : APP_DOCUMENT_TITLE;
  });

  watch(
    title,
    (nextTitle) => {
      document.title = nextTitle;
    },
    { immediate: true }
  );

  return title;
}
