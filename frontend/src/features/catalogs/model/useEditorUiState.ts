import { ref, type Ref } from 'vue';

const tabStateByEditor = new Map<string, Ref<string>>();

export function useEditorTabState<T extends string>(editorKey: string, defaultTab: T): Ref<T> {
  const existing = tabStateByEditor.get(editorKey);
  if (existing) return existing as Ref<T>;

  const state = ref(defaultTab) as Ref<T>;
  tabStateByEditor.set(editorKey, state as Ref<string>);
  return state;
}
