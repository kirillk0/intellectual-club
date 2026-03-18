import { computed, ref } from 'vue';

export type KnowledgeBlockLinkItem = {
  id: number;
  block: number;
  enabled: boolean;
  sequence: number;
  selection?: 'top' | 'bottom';
};

type BindingPayloadItem = {
  id?: number;
  knowledge_block_id: number;
  enabled: boolean;
  selection?: 'top' | 'bottom';
};

function selectionWeight(selection?: 'top' | 'bottom') {
  return selection === 'top' ? 0 : 1;
}

function sortBySequence(items: KnowledgeBlockLinkItem[]) {
  return [...(items || [])].sort(
    (a, b) =>
      selectionWeight(a.selection) - selectionWeight(b.selection) ||
      a.sequence - b.sequence ||
      a.id - b.id
  );
}

function normalizeSequences(items: KnowledgeBlockLinkItem[]) {
  return sortBySequence(items || []).map((item, idx) => ({ ...item, sequence: idx }));
}

function reindexInCurrentOrder(items: KnowledgeBlockLinkItem[]) {
  return [...(items || [])].map((item, idx) => ({ ...item, sequence: idx }));
}

function normalizeForCompare(items: KnowledgeBlockLinkItem[]) {
  return sortBySequence(items).map((i) => ({
    block: i.block,
    enabled: Boolean(i.enabled),
    selection: i.selection,
    sequence: Number(i.sequence) || 0,
  }));
}

function normalizeSelection(value: unknown, enabled: boolean) {
  if (!enabled) return undefined;
  return value === 'top' ? 'top' : 'bottom';
}

export function useKnowledgeBlockBindingsDraft(params: {
  selectionEnabled?: boolean;
  defaultSelection?: 'top' | 'bottom';
}) {
  const original = ref<KnowledgeBlockLinkItem[]>([]);
  const draft = ref<KnowledgeBlockLinkItem[]>([]);
  const loading = ref(false);
  const loaded = ref(false);
  const error = ref<string | null>(null);
  const selectionEnabled = params.selectionEnabled === true;
  const defaultSelection = params.defaultSelection === 'top' ? 'top' : 'bottom';

  let tempId = -1;

  const linkedBlockIds = computed(() => draft.value.map((i) => i.block));

  const dirty = computed(() => {
    return JSON.stringify(normalizeForCompare(original.value)) !== JSON.stringify(normalizeForCompare(draft.value));
  });

  const payload = computed<BindingPayloadItem[] | undefined>(() => {
    if (!loaded.value) return undefined;
    return (draft.value || []).map((i) => ({
      ...(i.id > 0 ? { id: i.id } : {}),
      knowledge_block_id: i.block,
      enabled: Boolean(i.enabled),
      ...(selectionEnabled ? { selection: normalizeSelection(i.selection, true) } : {}),
    }));
  });

  const reset = () => {
    draft.value = original.value.map((i) => ({ ...i }));
  };

  const hydrate = (items: KnowledgeBlockLinkItem[] | null | undefined) => {
    const normalized = normalizeSequences(
      sortBySequence(items || []).map((item) => ({
        ...item,
        enabled: Boolean(item.enabled),
        sequence: Number(item.sequence) || 0,
        ...(selectionEnabled ? { selection: normalizeSelection(item.selection, Boolean(item.enabled)) } : {}),
      }))
    );

    original.value = normalized.map((item) => ({ ...item }));
    draft.value = normalized.map((item) => ({ ...item }));
    tempId = -1;
    error.value = null;
    loading.value = false;
    loaded.value = true;
  }

  const touch = () => {
    // Useful for parity with older code paths.
  };

  const addBlocks = (blockIds: number[]) => {
    const existing = new Set(linkedBlockIds.value);
    const additions = (blockIds || []).filter((id) => !existing.has(id));
    if (!additions.length) return;

    const next = [...draft.value];
    for (const id of additions) {
      next.push({
        id: tempId--,
        block: id,
        enabled: true,
        sequence: 0,
        ...(selectionEnabled ? { selection: defaultSelection } : {}),
      });
    }

    draft.value = normalizeSequences(next);
  };

  const remove = (bindingId: number) => {
    draft.value = normalizeSequences(draft.value.filter((b) => b.id !== bindingId));
  };

  const setEnabled = (bindingId: number, enabled: boolean) => {
    draft.value = draft.value.map((b) => (b.id === bindingId ? { ...b, enabled } : b));
  };

  const setSelection = (bindingId: number, selection: 'top' | 'bottom') => {
    if (!selectionEnabled) return;

    draft.value = normalizeSequences(
      draft.value.map((b) => (b.id === bindingId ? { ...b, selection } : b))
    );
  };

  const move = (bindingId: number, delta: number) => {
    const current = sortBySequence(draft.value);
    const idx = current.findIndex((b) => b.id === bindingId);
    if (idx < 0) return;
    const target = idx + delta;
    if (target < 0 || target >= current.length) return;

    if (selectionEnabled && current[idx].selection !== current[target].selection) return;

    const next = [...current];
    const tmp = next[idx];
    next[idx] = next[target];
    next[target] = tmp;
    draft.value = reindexInCurrentOrder(next);
  };

  return {
    original,
    draft,
    loading,
    loaded,
    error,
    dirty,
    linkedBlockIds,
    payload,
    hydrate,
    reset,
    touch,
    addBlocks,
    remove,
    setEnabled,
    setSelection,
    move,
  };
}
