import { computed, ref, toValue, watch, type MaybeRefOrGetter } from 'vue';

import {
  createJsonApiIncludedIndex,
  jsonApiGet,
  jsonApiList,
  relatedResource,
  relatedResources,
  relationshipId,
  toIntId,
  type JsonApiResource,
  type JsonApiSingleResponse,
} from '@/api/jsonApi';

export type KnowledgeTagRow = {
  id: number;
  name: string;
  full_name: string;
  parent_id: number | null;
};

type TagBinding = {
  id: number;
  tagId: number;
};

export type KnowledgeBlockTagBindingPayloadItem = {
  id?: number;
  knowledge_tag_id: number;
};

function stableIds(ids: number[]) {
  return Array.from(new Set(ids || [])).sort((a, b) => a - b);
}

function parseTagRow(resource: JsonApiResource | null | undefined): KnowledgeTagRow | null {
  if (!resource) return null;
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const parentId =
    (typeof attrs.parent_id === 'number' ? attrs.parent_id : toIntId(attrs.parent_id as any)) ??
    relationshipId(resource, 'parent');

  return {
    id,
    name: String(attrs.name || '').trim(),
    full_name: String(attrs.full_name || '').trim(),
    parent_id: parentId ?? null,
  };
}

function parseTagBinding(resource: JsonApiResource): TagBinding | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const tagId = relationshipId(resource, 'knowledge_tag') ?? toIntId(attrs.knowledge_tag_id as any);
  if (!tagId) return null;

  return { id, tagId };
}

export function useKnowledgeBlockTagsDraft(params: {
  isNew: MaybeRefOrGetter<boolean>;
  defaultTagId: MaybeRefOrGetter<number | null | undefined>;
}) {
  const tagModalOpen = ref(false);
  const allTagsLoading = ref(false);
  const allTagsError = ref<string | null>(null);
  const allTags = ref<KnowledgeTagRow[]>([]);
  const tagBindingsLoading = ref(false);
  const tagBindingsError = ref<string | null>(null);
  const originalTagBindings = ref<TagBinding[]>([]);
  const draftTagBindings = ref<TagBinding[]>([]);
  const includedTags = ref<KnowledgeTagRow[]>([]);
  let tempTagBindingId = -1;

  const tagsDirty = computed(() => {
    const base = stableIds(originalTagBindings.value.map((b) => b.tagId));
    const current = stableIds(draftTagBindings.value.map((b) => b.tagId));
    return JSON.stringify(base) !== JSON.stringify(current);
  });

  const tagBindingsPayload = computed<KnowledgeBlockTagBindingPayloadItem[] | undefined>(() => {
    const items = (draftTagBindings.value || []).map((b) => ({
      ...(b.id > 0 ? { id: b.id } : {}),
      knowledge_tag_id: b.tagId,
    }));

    if (toValue(params.isNew)) return items;
    if (!tagsDirty.value) return undefined;
    return items;
  });

  const tagById = computed(() => {
    const map = new Map<number, KnowledgeTagRow>();
    for (const t of includedTags.value || []) map.set(t.id, t);
    for (const t of allTags.value || []) map.set(t.id, t);
    return map;
  });

  function mergeKnownTags(tags: KnowledgeTagRow[]) {
    const byId = new Map<number, KnowledgeTagRow>();
    for (const tag of includedTags.value || []) byId.set(tag.id, tag);
    for (const tag of allTags.value || []) byId.set(tag.id, tag);
    for (const tag of tags || []) byId.set(tag.id, tag);
    allTags.value = Array.from(byId.values()).sort((a, b) => {
      const left = a.full_name || a.name;
      const right = b.full_name || b.name;
      return left.localeCompare(right) || a.id - b.id;
    });
  }

  const attachedTagIds = computed(() => {
    return stableIds(draftTagBindings.value.map((b) => b.tagId));
  });

  const attachedTags = computed(() => {
    const ids = draftTagBindings.value.map((b) => b.tagId);
    const uniqueInOrder: number[] = [];
    const seen = new Set<number>();
    for (const id of ids) {
      if (seen.has(id)) continue;
      seen.add(id);
      uniqueInOrder.push(id);
    }

    return uniqueInOrder.map((id) => tagById.value.get(id) || { id, name: `Tag #${id}`, full_name: '', parent_id: null });
  });

  function applyDocument(payload: JsonApiSingleResponse) {
    const includedIndex = createJsonApiIncludedIndex(payload.included);
    const root = payload.data;
    const bindingResources = relatedResources(root, 'tag_bindings', includedIndex);

    originalTagBindings.value = bindingResources.map(parseTagBinding).filter((b): b is TagBinding => Boolean(b));
    draftTagBindings.value = originalTagBindings.value.map((binding) => ({ ...binding }));
    const documentTags = bindingResources
      .map((resource) => parseTagRow(relatedResource(resource, 'knowledge_tag', includedIndex)))
      .filter((tag): tag is KnowledgeTagRow => Boolean(tag));
    includedTags.value = documentTags;
    mergeKnownTags(documentTags);
    tempTagBindingId = -1;
    tagBindingsLoading.value = false;
    tagBindingsError.value = null;
  }

  async function ensureTagsLoaded(tagIds: number[]) {
    const missingIds = stableIds(tagIds).filter((id) => id > 0 && !tagById.value.has(id));
    if (!missingIds.length) return;

    const loadedTags: KnowledgeTagRow[] = [];

    await Promise.all(
      missingIds.map(async (tagId) => {
        try {
          const payload = await jsonApiGet(`/api/ash/knowledge-tags/${tagId}`);
          const tag = parseTagRow(payload.data);
          if (tag) loadedTags.push(tag);
        } catch (error) {
          console.warn(`Failed to load knowledge tag ${tagId}`, error);
        }
      })
    );

    if (loadedTags.length) mergeKnownTags(loadedTags);
  }

  async function loadAllTags() {
    if (allTagsLoading.value) return;
    allTagsLoading.value = true;
    allTagsError.value = null;

    try {
      const tagParams = new URLSearchParams();
      tagParams.set('sort', 'full_name');
      const payload = await jsonApiList('/api/ash/knowledge-tags', tagParams);
      allTags.value = (payload.data || []).map(parseTagRow).filter((t): t is KnowledgeTagRow => Boolean(t));
    } catch (e) {
      console.error(e);
      const message = e instanceof Error ? e.message : 'Failed to load tags.';
      if (message.startsWith('HTTP 403') || message.startsWith('HTTP 401')) {
        allTags.value = [];
        allTagsError.value = null;
      } else {
        allTagsError.value = message;
      }
    } finally {
      allTagsLoading.value = false;
    }
  }

  function openTagModal() {
    tagModalOpen.value = true;
    if (!allTagsLoading.value && !allTags.value.length) void loadAllTags();
  }

  function addTag(tagId: number) {
    if (!tagId) return;
    if (attachedTagIds.value.includes(tagId)) return;

    const original = originalTagBindings.value.find((b) => b.tagId === tagId);
    if (original) {
      draftTagBindings.value = [...draftTagBindings.value, { ...original }];
      return;
    }

    draftTagBindings.value = [...draftTagBindings.value, { id: tempTagBindingId--, tagId }];
  }

  function removeTag(tagId: number) {
    if (!tagId) return;
    draftTagBindings.value = draftTagBindings.value.filter((b) => b.tagId !== tagId);
  }

  function toggleTag(tagId: number) {
    if (!tagId) return;
    if (attachedTagIds.value.includes(tagId)) removeTag(tagId);
    else addTag(tagId);
  }

  function reset() {
    draftTagBindings.value = (originalTagBindings.value || []).map((b) => ({ ...b }));
  }

  watch(
    () => toValue(params.isNew),
    (value) => {
      if (!value) return;
      tempTagBindingId = -1;
      originalTagBindings.value = [];
      draftTagBindings.value = [];
      includedTags.value = [];
      allTagsError.value = null;
      tagBindingsError.value = null;
    },
    { immediate: true }
  );

  watch(
    () => [toValue(params.isNew), toValue(params.defaultTagId)] as const,
    ([newRecord, tagId]) => {
      if (!newRecord) return;
      if (!tagId) return;
      if (originalTagBindings.value.length === 0 && draftTagBindings.value.length === 0) {
        const binding = { id: tempTagBindingId--, tagId };
        originalTagBindings.value = [binding];
        draftTagBindings.value = [binding];
      }
    },
    { immediate: true }
  );

  watch(
    () => attachedTagIds.value,
    (tagIds) => {
      if (!tagIds.length) return;
      void ensureTagsLoaded(tagIds);
    },
    { immediate: true }
  );

  return {
    tagModalOpen,
    allTagsLoading,
    allTagsError,
    allTags,
    tagBindingsLoading,
    tagBindingsError,
    tagsDirty,
    tagBindingsPayload,
    attachedTagIds,
    attachedTags,
    applyDocument,
    openTagModal,
    toggleTag,
    removeTag,
    reset,
  };
}

