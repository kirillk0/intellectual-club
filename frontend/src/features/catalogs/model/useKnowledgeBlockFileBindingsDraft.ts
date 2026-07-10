import { computed, ref, toValue, watch, type MaybeRefOrGetter } from 'vue';
import { useQuery } from '@tanstack/vue-query';

import { getApiErrorMessage } from '@/api/client';
import {
  deleteKnowledgeBlockFile,
  listKnowledgeBlockFiles,
  updateKnowledgeBlockFile,
  uploadKnowledgeBlockFile,
} from '@/api/knowledgeBlockFiles';
import { serverStateKeys, serverStateQueryClient } from '@/features/serverState/queryClient';
import type { KnowledgeBlockAttachment } from '@/types/api';

export type KnowledgeBlockFileDraftItem = KnowledgeBlockAttachment & {
  pendingFile?: File;
};

export type KnowledgeBlockFilesSnapshot = {
  blockId: number;
  attachments: KnowledgeBlockAttachment[];
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

function attachmentsFingerprint(attachments: KnowledgeBlockAttachment[]) {
  return JSON.stringify(
    sortDraftItems(normalizeAttachments(attachments)).map((item) => ({
      id: item.id,
      external_id: item.external_id,
      file_id: item.file_id,
      filename: item.filename,
      mime_type: item.mime_type,
      size_bytes: item.size_bytes,
      sha256: item.sha256,
      sequence: item.sequence,
      enabled: item.enabled,
    }))
  );
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

function filesQueryKey(blockId: number | 'new') {
  return serverStateKeys.detail('knowledge-blocks', blockId, 'file-attachments');
}

function createSnapshot(blockId: number, attachments: KnowledgeBlockAttachment[]): KnowledgeBlockFilesSnapshot {
  return { blockId, attachments: normalizeAttachments(attachments) };
}

export function isPendingKnowledgeBlockFile(item: KnowledgeBlockFileDraftItem) {
  return item.id < 0 || Boolean(item.pendingFile);
}

export function useKnowledgeBlockFileBindingsDraft(params: {
  enabled?: MaybeRefOrGetter<boolean>;
} = {}) {
  const activeBlockId = ref<number | null>(null);
  const original = ref<KnowledgeBlockAttachment[]>([]);
  const draft = ref<KnowledgeBlockFileDraftItem[]>([]);
  const loaded = ref(false);
  const syncing = ref(false);
  const operationError = ref<string | null>(null);
  const remoteUpdateAvailable = ref(false);
  const remoteSnapshot = ref<KnowledgeBlockFilesSnapshot | null>(null);
  let canonicalFingerprint = '';
  let dismissedRemoteFingerprint = '';
  let sessionVersion = 0;
  let tempId = -1;

  const attachmentsQuery = useQuery<KnowledgeBlockFilesSnapshot>({
    queryKey: computed(() => filesQueryKey(activeBlockId.value ?? 'new')),
    enabled: computed(
      () => activeBlockId.value !== null && (params.enabled === undefined || toValue(params.enabled))
    ),
    queryFn: async ({ queryKey, signal }) => {
      const requestedId = Number(queryKey[3]);
      if (!Number.isFinite(requestedId) || requestedId <= 0) throw new Error('Invalid knowledge block id.');
      const response = await listKnowledgeBlockFiles(requestedId, { signal });
      return createSnapshot(requestedId, response.attachments);
    },
  });

  const loading = computed(
    () => activeBlockId.value !== null && !loaded.value && attachmentsQuery.isPending.value
  );
  const error = computed(() => {
    if (operationError.value) return operationError.value;
    if (attachmentsQuery.data.value || !attachmentsQuery.error.value) return null;
    return attachmentsQuery.error.value instanceof Error
      ? attachmentsQuery.error.value.message
      : 'Failed to load files.';
  });

  const dirty = computed(() => {
    if (!loaded.value) return false;
    return JSON.stringify(normalizeForCompare(original.value)) !== JSON.stringify(normalizeForCompare(draft.value));
  });

  function clearRemoteUpdate() {
    dismissedRemoteFingerprint = '';
    remoteSnapshot.value = null;
    remoteUpdateAvailable.value = false;
  }

  function applyCanonicalAttachments(attachments: KnowledgeBlockAttachment[] | null | undefined) {
    const normalized = normalizeAttachments(attachments);
    original.value = normalized.map((item) => ({ ...item }));
    draft.value = normalized.map((item) => ({ ...item }));
    canonicalFingerprint = attachmentsFingerprint(normalized);
    clearRemoteUpdate();
    tempId = -1;
    operationError.value = null;
    loaded.value = true;
  }

  function hydrate(attachments: KnowledgeBlockAttachment[] | null | undefined) {
    sessionVersion += 1;
    activeBlockId.value = null;
    applyCanonicalAttachments(attachments);
  }

  function startSession() {
    sessionVersion += 1;
    original.value = [];
    draft.value = [];
    loaded.value = false;
    operationError.value = null;
    canonicalFingerprint = '';
    clearRemoteUpdate();
    tempId = -1;
  }

  async function load(blockId: number) {
    if (!Number.isFinite(blockId) || blockId <= 0) return;

    if (activeBlockId.value !== blockId) {
      startSession();
      activeBlockId.value = blockId;
      return;
    }

    await attachmentsQuery.refetch({ cancelRefetch: true });
  }

  function applyQuerySnapshot(snapshot: KnowledgeBlockFilesSnapshot | undefined) {
    if (!snapshot || snapshot.blockId !== activeBlockId.value) return;

    const nextFingerprint = attachmentsFingerprint(snapshot.attachments);
    if (nextFingerprint === canonicalFingerprint) {
      loaded.value = true;
      return;
    }

    if (syncing.value) return;

    if (!loaded.value) {
      applyCanonicalAttachments(snapshot.attachments);
      return;
    }

    if (dirty.value) {
      if (nextFingerprint === dismissedRemoteFingerprint) return;
      remoteSnapshot.value = snapshot;
      remoteUpdateAvailable.value = true;
      return;
    }

    applyCanonicalAttachments(snapshot.attachments);
  }

  watch(
    () => attachmentsQuery.data.value,
    (snapshot) => applyQuerySnapshot(snapshot),
    { immediate: true }
  );

  function reset() {
    draft.value = original.value.map((item) => ({ ...item }));
    tempId = -1;
    operationError.value = null;
  }

  function addFiles(files: File[]) {
    const selected = files || [];
    if (!selected.length) return;

    let sequence = Math.max(-1, ...draft.value.map((item) => Number(item.sequence) || 0)) + 1;
    const additions = selected.map((file) => pendingAttachment(file, tempId--, sequence++));
    draft.value = [...draft.value, ...additions];
    operationError.value = null;
  }

  function remove(id: number) {
    draft.value = draft.value.filter((item) => item.id !== id);
    operationError.value = null;
  }

  function setEnabled(id: number, enabled: boolean) {
    draft.value = draft.value.map((item) => (item.id === id ? { ...item, enabled } : item));
    operationError.value = null;
  }

  function cacheSnapshot(blockId: number, attachments: KnowledgeBlockAttachment[]) {
    const snapshot = createSnapshot(blockId, attachments);
    serverStateQueryClient.setQueryData(filesQueryKey(blockId), snapshot);
    return snapshot;
  }

  async function reloadRemoteFiles() {
    const pending = remoteSnapshot.value;
    if (pending && pending.blockId === activeBlockId.value) {
      applyCanonicalAttachments(pending.attachments);
    }

    if (activeBlockId.value !== null) {
      const requestedId = activeBlockId.value;
      const result = await attachmentsQuery.refetch({ cancelRefetch: true });
      if (result.data?.blockId === requestedId && activeBlockId.value === requestedId) {
        applyCanonicalAttachments(result.data.attachments);
      }
    }
  }

  function keepEditingRemoteFiles() {
    if (remoteSnapshot.value) {
      dismissedRemoteFingerprint = attachmentsFingerprint(remoteSnapshot.value.attachments);
    }
    remoteSnapshot.value = null;
    remoteUpdateAvailable.value = false;
  }

  async function reconcileAfterFailure(
    blockId: number,
    desiredDraft: KnowledgeBlockFileDraftItem[],
    uploadedPendingIds: Set<number>,
    expectedSessionVersion: number
  ) {
    try {
      const response = await listKnowledgeBlockFiles(blockId);
      const serverAttachments = normalizeAttachments(response.attachments);
      const serverById = new Map(serverAttachments.map((item) => [item.id, item]));

      cacheSnapshot(blockId, serverAttachments);
      if (sessionVersion !== expectedSessionVersion) return;
      original.value = serverAttachments.map((item) => ({ ...item }));
      draft.value = desiredDraft.flatMap((desired) => {
        if (isPendingKnowledgeBlockFile(desired)) {
          return uploadedPendingIds.has(desired.id) ? [] : [cloneDraftItem(desired)];
        }

        const serverItem = serverById.get(desired.id);
        return serverItem ? [{ ...serverItem, enabled: desired.enabled !== false }] : [];
      });
      canonicalFingerprint = attachmentsFingerprint(serverAttachments);
      clearRemoteUpdate();
      loaded.value = true;
    } catch (reloadError) {
      console.error(reloadError);
    }
  }

  async function sync(blockId: number) {
    if (!loaded.value || !dirty.value) return;

    const syncSessionVersion = sessionVersion;
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
    operationError.value = null;

    try {
      let latestAttachments: KnowledgeBlockAttachment[] | null = null;

      for (const attachment of removed) {
        const response = await deleteKnowledgeBlockFile(blockId, attachment.id);
        latestAttachments = normalizeAttachments(response.attachments);
        cacheSnapshot(blockId, latestAttachments);
      }

      for (const attachment of changed) {
        const response = await updateKnowledgeBlockFile(blockId, attachment.id, {
          enabled: attachment.enabled !== false,
        });
        latestAttachments = normalizeAttachments(response.attachments);
        cacheSnapshot(blockId, latestAttachments);
      }

      for (const attachment of pending) {
        if (!attachment.pendingFile) continue;
        const response = await uploadKnowledgeBlockFile(blockId, attachment.pendingFile, {
          enabled: attachment.enabled !== false,
        });
        uploadedPendingIds.add(attachment.id);
        latestAttachments = normalizeAttachments(response.attachments);
        cacheSnapshot(blockId, latestAttachments);
      }

      if (!latestAttachments) {
        const response = await listKnowledgeBlockFiles(blockId);
        latestAttachments = normalizeAttachments(response.attachments);
        cacheSnapshot(blockId, latestAttachments);
      }

      if (sessionVersion === syncSessionVersion) applyCanonicalAttachments(latestAttachments);
    } catch (syncError) {
      console.error(syncError);
      if (sessionVersion === syncSessionVersion) {
        operationError.value = getApiErrorMessage(syncError, 'Failed to save file changes.');
      }
      await reconcileAfterFailure(blockId, draftSnapshot, uploadedPendingIds, syncSessionVersion);
      throw syncError;
    } finally {
      syncing.value = false;
      applyQuerySnapshot(attachmentsQuery.data.value);
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
    remoteUpdateAvailable,
    hydrate,
    load,
    reloadRemoteFiles,
    keepEditingRemoteFiles,
    reset,
    addFiles,
    remove,
    setEnabled,
    sync,
  };
}
