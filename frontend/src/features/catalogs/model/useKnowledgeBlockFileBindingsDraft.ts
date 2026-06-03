import { computed, ref } from 'vue';

import { getApiErrorMessage } from '@/api/client';
import {
  deleteKnowledgeBlockFile,
  listKnowledgeBlockFiles,
  updateKnowledgeBlockFile,
  uploadKnowledgeBlockFile,
} from '@/api/knowledgeBlockFiles';
import type { KnowledgeBlockAttachment } from '@/types/api';

export type KnowledgeBlockFileDraftItem = KnowledgeBlockAttachment & {
  pendingFile?: File;
};

function normalizeAttachment(attachment: KnowledgeBlockAttachment): KnowledgeBlockAttachment {
  return {
    ...attachment,
    sequence: Number(attachment.sequence) || 0,
    enabled: attachment.enabled !== false,
  };
}

function normalizeAttachments(attachments: KnowledgeBlockAttachment[] | null | undefined) {
  return (attachments || []).map(normalizeAttachment);
}

function cloneDraftItem(item: KnowledgeBlockFileDraftItem): KnowledgeBlockFileDraftItem {
  return { ...item };
}

function sortDraftItems(items: KnowledgeBlockFileDraftItem[]) {
  return [...(items || [])].sort((a, b) => a.sequence - b.sequence || a.id - b.id);
}

function normalizeForCompare(items: KnowledgeBlockFileDraftItem[]) {
  return sortDraftItems(items).map((item) => ({
    id: item.id > 0 ? item.id : `pending:${item.id}`,
    filename: item.id > 0 ? undefined : item.filename,
    mime_type: item.id > 0 ? undefined : item.mime_type,
    size_bytes: item.id > 0 ? undefined : item.size_bytes,
    enabled: item.enabled !== false,
    sequence: Number(item.sequence) || 0,
  }));
}

function pendingAttachment(file: File, id: number, sequence: number): KnowledgeBlockFileDraftItem {
  return {
    id,
    external_id: `pending-${Math.abs(id)}`,
    file_id: '',
    filename: file.name,
    mime_type: file.type || 'application/octet-stream',
    size_bytes: file.size,
    sha256: '',
    sequence,
    enabled: true,
    url: '',
    pendingFile: file,
  };
}

export function isPendingKnowledgeBlockFile(item: KnowledgeBlockFileDraftItem) {
  return item.id < 0 || Boolean(item.pendingFile);
}

export function useKnowledgeBlockFileBindingsDraft() {
  const original = ref<KnowledgeBlockAttachment[]>([]);
  const draft = ref<KnowledgeBlockFileDraftItem[]>([]);
  const loading = ref(false);
  const loaded = ref(false);
  const syncing = ref(false);
  const error = ref<string | null>(null);
  let tempId = -1;

  const dirty = computed(() => {
    if (!loaded.value) return false;
    return JSON.stringify(normalizeForCompare(original.value)) !== JSON.stringify(normalizeForCompare(draft.value));
  });

  function hydrate(attachments: KnowledgeBlockAttachment[] | null | undefined) {
    const normalized = normalizeAttachments(attachments);
    original.value = normalized.map((item) => ({ ...item }));
    draft.value = normalized.map((item) => ({ ...item }));
    tempId = -1;
    error.value = null;
    loading.value = false;
    loaded.value = true;
  }

  async function load(blockId: number) {
    loading.value = true;
    loaded.value = false;
    error.value = null;

    try {
      const response = await listKnowledgeBlockFiles(blockId);
      hydrate(response.attachments);
    } catch (loadError) {
      console.error(loadError);
      original.value = [];
      draft.value = [];
      error.value = getApiErrorMessage(loadError, 'Failed to load files.');
    } finally {
      loading.value = false;
    }
  }

  function reset() {
    draft.value = original.value.map((item) => ({ ...item }));
    tempId = -1;
    error.value = null;
  }

  function addFiles(files: File[]) {
    const selected = files || [];
    if (!selected.length) return;

    let sequence = Math.max(-1, ...draft.value.map((item) => Number(item.sequence) || 0)) + 1;
    const additions = selected.map((file) => pendingAttachment(file, tempId--, sequence++));
    draft.value = [...draft.value, ...additions];
    error.value = null;
  }

  function remove(id: number) {
    draft.value = draft.value.filter((item) => item.id !== id);
    error.value = null;
  }

  function setEnabled(id: number, enabled: boolean) {
    draft.value = draft.value.map((item) => (item.id === id ? { ...item, enabled } : item));
    error.value = null;
  }

  async function reconcileAfterFailure(
    blockId: number,
    desiredDraft: KnowledgeBlockFileDraftItem[],
    uploadedPendingIds: Set<number>
  ) {
    try {
      const response = await listKnowledgeBlockFiles(blockId);
      const serverAttachments = normalizeAttachments(response.attachments);
      const serverById = new Map(serverAttachments.map((item) => [item.id, item]));

      original.value = serverAttachments.map((item) => ({ ...item }));
      draft.value = desiredDraft.flatMap((desired) => {
        if (isPendingKnowledgeBlockFile(desired)) {
          return uploadedPendingIds.has(desired.id) ? [] : [cloneDraftItem(desired)];
        }

        const serverItem = serverById.get(desired.id);
        return serverItem ? [{ ...serverItem, enabled: desired.enabled !== false }] : [];
      });
      loaded.value = true;
    } catch (reloadError) {
      console.error(reloadError);
    }
  }

  async function sync(blockId: number) {
    if (!loaded.value || !dirty.value) return;

    const originalSnapshot = original.value.map((item) => ({ ...item }));
    const draftSnapshot = draft.value.map(cloneDraftItem);
    const draftPersistedById = new Map(
      draftSnapshot.filter((item) => !isPendingKnowledgeBlockFile(item)).map((item) => [item.id, item])
    );
    const originalById = new Map(originalSnapshot.map((item) => [item.id, item]));
    const removed = originalSnapshot.filter((item) => !draftPersistedById.has(item.id));
    const changed = draftSnapshot.filter((item) => {
      if (isPendingKnowledgeBlockFile(item)) return false;
      const persisted = originalById.get(item.id);
      if (!persisted) return false;
      return (persisted.enabled !== false) !== (item.enabled !== false);
    });
    const pending = draftSnapshot.filter((item) => isPendingKnowledgeBlockFile(item) && item.pendingFile);
    const uploadedPendingIds = new Set<number>();

    syncing.value = true;
    error.value = null;

    try {
      let latestAttachments: KnowledgeBlockAttachment[] | null = null;

      for (const attachment of removed) {
        const response = await deleteKnowledgeBlockFile(blockId, attachment.id);
        latestAttachments = normalizeAttachments(response.attachments);
      }

      for (const attachment of changed) {
        const response = await updateKnowledgeBlockFile(blockId, attachment.id, {
          enabled: attachment.enabled !== false,
        });
        latestAttachments = normalizeAttachments(response.attachments);
      }

      for (const attachment of pending) {
        if (!attachment.pendingFile) continue;
        const response = await uploadKnowledgeBlockFile(blockId, attachment.pendingFile, {
          enabled: attachment.enabled !== false,
        });
        uploadedPendingIds.add(attachment.id);
        latestAttachments = normalizeAttachments(response.attachments);
      }

      if (!latestAttachments) {
        const response = await listKnowledgeBlockFiles(blockId);
        latestAttachments = normalizeAttachments(response.attachments);
      }

      hydrate(latestAttachments);
    } catch (syncError) {
      console.error(syncError);
      error.value = getApiErrorMessage(syncError, 'Failed to save file changes.');
      await reconcileAfterFailure(blockId, draftSnapshot, uploadedPendingIds);
      throw syncError;
    } finally {
      syncing.value = false;
    }
  }

  return {
    original,
    draft,
    loading,
    loaded,
    syncing,
    error,
    dirty,
    hydrate,
    load,
    reset,
    addFiles,
    remove,
    setEnabled,
    sync,
  };
}
