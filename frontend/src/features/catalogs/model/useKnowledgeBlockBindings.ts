import { computed, ref } from 'vue';
import {
  jsonApiCreate,
  jsonApiDelete,
  jsonApiList,
  jsonApiUpdate,
  relationshipId,
  toIntId,
  type JsonApiResource,
} from '@/api/jsonApi';

export type KnowledgeBlockBinding = {
  id: number;
  enabled: boolean;
  sequence: number;
  knowledge_block_id: number;
};

function parseBinding(resource: JsonApiResource): KnowledgeBlockBinding | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const knowledgeBlockId =
    relationshipId(resource, 'knowledge_block') ?? toIntId(attrs.knowledge_block_id as string | number | null);
  if (!knowledgeBlockId) return null;

  return {
    id,
    enabled: Boolean(attrs.enabled),
    sequence: typeof attrs.sequence === 'number' ? attrs.sequence : Number(attrs.sequence || 0),
    knowledge_block_id: knowledgeBlockId,
  };
}

function sortBindings(bindings: KnowledgeBlockBinding[]) {
  return [...bindings].sort((a, b) => (a.sequence - b.sequence) || (a.id - b.id));
}

function jsonApiTypeFromBasePath(basePath: string): string {
  return basePath.split('/').filter(Boolean).pop() || '';
}

export function useKnowledgeBlockBindings(params: {
  basePath: string;
  ownerIdAttr: string;
  ownerId: () => number | undefined;
}) {
  const bindings = ref<KnowledgeBlockBinding[]>([]);
  const loading = ref(false);
  const saving = ref(false);
  const error = ref<string | null>(null);

  const ordered = computed(() => sortBindings(bindings.value));

  async function load() {
    const ownerId = params.ownerId();
    if (!ownerId) {
      bindings.value = [];
      return;
    }
    loading.value = true;
    error.value = null;
    try {
      const qs = new URLSearchParams();
      qs.set(`filter[${params.ownerIdAttr}]`, String(ownerId));
      qs.set('sort', 'sequence');
      const payload = await jsonApiList(params.basePath, qs);
      bindings.value = (payload.data || [])
        .map(parseBinding)
        .filter((b): b is KnowledgeBlockBinding => Boolean(b));
    } catch (e) {
      console.error(e);
      error.value = e instanceof Error ? e.message : 'Failed to load bindings.';
    } finally {
      loading.value = false;
    }
  }

  async function addBlocks(blockIds: number[]) {
    const ownerId = params.ownerId();
    if (!ownerId) return;
    const existing = new Set(ordered.value.map((b) => b.knowledge_block_id));
    const toAdd = blockIds.filter((id) => !existing.has(id));
    if (!toAdd.length) return;
    saving.value = true;
    error.value = null;

    try {
      let nextSequence = Math.max(-1, ...ordered.value.map((b) => b.sequence)) + 1;
      for (const blockId of toAdd) {
        await jsonApiCreate(params.basePath, jsonApiTypeFromBasePath(params.basePath), {
          [params.ownerIdAttr]: ownerId,
          knowledge_block_id: blockId,
          enabled: true,
          sequence: nextSequence,
        });
        nextSequence += 1;
      }
      await load();
    } catch (e) {
      console.error(e);
      error.value = e instanceof Error ? e.message : 'Failed to add blocks.';
    } finally {
      saving.value = false;
    }
  }

  async function remove(bindingId: number) {
    saving.value = true;
    error.value = null;
    try {
      await jsonApiDelete(params.basePath, bindingId);
      bindings.value = bindings.value.filter((b) => b.id !== bindingId);
    } catch (e) {
      console.error(e);
      error.value = e instanceof Error ? e.message : 'Failed to remove binding.';
    } finally {
      saving.value = false;
    }
  }

  async function setEnabled(bindingId: number, enabled: boolean) {
    saving.value = true;
    error.value = null;
    try {
      await jsonApiUpdate(params.basePath, jsonApiTypeFromBasePath(params.basePath), bindingId, { enabled });
      bindings.value = bindings.value.map((b) => (b.id === bindingId ? { ...b, enabled } : b));
    } catch (e) {
      console.error(e);
      error.value = e instanceof Error ? e.message : 'Failed to update binding.';
    } finally {
      saving.value = false;
    }
  }

  async function resequence(nextOrdered: KnowledgeBlockBinding[]) {
    const updates: Array<{ id: number; sequence: number }> = [];
    nextOrdered.forEach((b, idx) => {
      if (b.sequence !== idx) updates.push({ id: b.id, sequence: idx });
    });

    if (!updates.length) {
      bindings.value = nextOrdered;
      return;
    }

    saving.value = true;
    error.value = null;
    try {
      await Promise.all(
        updates.map((u) =>
          jsonApiUpdate(params.basePath, jsonApiTypeFromBasePath(params.basePath), u.id, {
            sequence: u.sequence,
          })
        )
      );
      bindings.value = nextOrdered.map((b, idx) => ({ ...b, sequence: idx }));
    } catch (e) {
      console.error(e);
      error.value = e instanceof Error ? e.message : 'Failed to reorder bindings.';
      await load();
    } finally {
      saving.value = false;
    }
  }

  async function move(bindingId: number, delta: number) {
    const current = sortBindings(bindings.value);
    const idx = current.findIndex((b) => b.id === bindingId);
    const target = idx + delta;
    if (idx < 0) return;
    if (target < 0 || target >= current.length) return;
    const next = [...current];
    const [item] = next.splice(idx, 1);
    next.splice(target, 0, item);
    await resequence(next);
  }

  return {
    bindings,
    ordered,
    loading,
    saving,
    error,
    load,
    addBlocks,
    remove,
    setEnabled,
    move,
  };
}
