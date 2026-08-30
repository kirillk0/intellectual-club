import { computed, ref, toValue, watch, type MaybeRefOrGetter } from 'vue';
import { useQuery } from '@tanstack/vue-query';

import { getApiErrorMessage } from '@/api/client';
import {
  createManagedSecret,
  deleteManagedSecret,
  listManagedSecrets,
  updateManagedSecret,
  type ManagedSecretAttachment,
  type SecretAttachmentParent,
} from '@/api/managedSecrets';
import { serverStateKeys, serverStateQueryClient } from '@/features/serverState/queryClient';
import { translate } from '@/i18n';

type ManagedSecretsSnapshot = {
  parent: SecretAttachmentParent;
  parentId: number;
  secrets: ManagedSecretAttachment[];
};

export type ManagedSecretDraftItem = ManagedSecretAttachment & {
  value?: string;
};

function managedSecretsQueryKey(parent: SecretAttachmentParent, parentId: number | 'new') {
  return serverStateKeys.detail(parent, parentId, 'managed-secrets');
}

function normalizeParentId(value: number | null | undefined) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : null;
}

function normalizeSecrets(secrets: ManagedSecretAttachment[] | null | undefined) {
  return (secrets || []).map((secret) => ({ ...secret }));
}

function cloneDraft(secret: ManagedSecretDraftItem): ManagedSecretDraftItem {
  return { ...secret };
}

function normalizeForCompare(secrets: ManagedSecretDraftItem[]) {
  return [...secrets]
    .sort((left, right) => left.id - right.id)
    .map((secret) => ({
      id: secret.id,
      name: secret.name,
      description: secret.description,
      env_name: secret.env_name,
      value: secret.value || undefined,
    }));
}

function secretsFingerprint(secrets: ManagedSecretAttachment[]) {
  return JSON.stringify(
    [...normalizeSecrets(secrets)]
      .sort((left, right) => left.id - right.id)
      .map((secret) => ({
        id: secret.id,
        external_id: secret.external_id,
        name: secret.name,
        description: secret.description,
        env_name: secret.env_name,
      }))
  );
}

export function useManagedSecretsState(params: {
  parent: SecretAttachmentParent;
  parentId: MaybeRefOrGetter<number | null | undefined>;
  enabled?: MaybeRefOrGetter<boolean>;
}) {
  const parentId = computed(() => normalizeParentId(toValue(params.parentId)));
  const activeParentId = ref<number | null>(parentId.value);
  const original = ref<ManagedSecretAttachment[]>([]);
  const draft = ref<ManagedSecretDraftItem[]>([]);
  const loaded = ref(parentId.value === null);
  const syncing = ref(false);
  const operationError = ref<string | null>(null);
  let canonicalFingerprint = '';
  let sessionVersion = 0;

  const enabled = computed(
    () => activeParentId.value !== null && (params.enabled === undefined || toValue(params.enabled))
  );

  const query = useQuery<ManagedSecretsSnapshot>({
    queryKey: computed(() => managedSecretsQueryKey(params.parent, activeParentId.value ?? 'new')),
    enabled,
    queryFn: async ({ queryKey, signal }) => {
      const requestedId = normalizeParentId(Number(queryKey[3]));
      if (!requestedId) throw new Error('Invalid managed secrets parent id.');

      const response = await listManagedSecrets(params.parent, requestedId, { signal });
      return {
        parent: params.parent,
        parentId: requestedId,
        secrets: response.secrets || [],
      };
    },
  });

  const secrets = computed(() => draft.value);
  const loading = computed(() => enabled.value && !loaded.value && query.isPending.value);
  const error = computed(() => {
    if (operationError.value) return operationError.value;
    if (loaded.value || !query.error.value) return null;
    return getApiErrorMessage(query.error.value, translate('Failed to load managed secrets.'));
  });

  const dirty = computed(() => {
    if (!loaded.value) return false;
    return JSON.stringify(normalizeForCompare(original.value)) !== JSON.stringify(normalizeForCompare(draft.value));
  });

  function cacheSnapshot(currentParentId: number, secrets: ManagedSecretAttachment[]) {
    const snapshot: ManagedSecretsSnapshot = {
      parent: params.parent,
      parentId: currentParentId,
      secrets: normalizeSecrets(secrets),
    };
    serverStateQueryClient.setQueryData(
      managedSecretsQueryKey(params.parent, currentParentId),
      snapshot
    );
    return snapshot;
  }

  function applyCanonicalSecrets(nextSecrets: ManagedSecretAttachment[] | null | undefined) {
    const normalized = normalizeSecrets(nextSecrets);
    original.value = normalized.map((secret) => ({ ...secret }));
    draft.value = normalized.map((secret) => ({ ...secret }));
    canonicalFingerprint = secretsFingerprint(normalized);
    operationError.value = null;
    loaded.value = true;
  }

  function startSession(nextParentId: number | null) {
    sessionVersion += 1;
    activeParentId.value = nextParentId;
    original.value = [];
    draft.value = [];
    operationError.value = null;
    canonicalFingerprint = '';
    loaded.value = nextParentId === null;
  }

  watch(
    parentId,
    (nextParentId) => {
      if (nextParentId === activeParentId.value) return;

      // Creating the parent changes its route from `new` to an id before the
      // surrounding editor can persist this draft. Keep that logical session intact.
      if (activeParentId.value === null && nextParentId !== null && loaded.value && dirty.value) {
        activeParentId.value = nextParentId;
        operationError.value = null;
        return;
      }

      startSession(nextParentId);
    },
    { immediate: true }
  );

  function applyQuerySnapshot(snapshot: ManagedSecretsSnapshot | undefined) {
    if (
      !snapshot ||
      snapshot.parent !== params.parent ||
      snapshot.parentId !== activeParentId.value
    ) {
      return;
    }

    const nextFingerprint = secretsFingerprint(snapshot.secrets);
    if (nextFingerprint === canonicalFingerprint) {
      loaded.value = true;
      return;
    }
    if (syncing.value || dirty.value) return;
    applyCanonicalSecrets(snapshot.secrets);
  }

  watch(
    () => query.data.value,
    (snapshot) => applyQuerySnapshot(snapshot),
    { immediate: true }
  );

  function replaceSecrets(nextSecrets: ManagedSecretDraftItem[]) {
    draft.value = (nextSecrets || []).map(cloneDraft);
    operationError.value = null;
    loaded.value = true;
  }

  function reset() {
    draft.value = original.value.map((secret) => ({ ...secret }));
    operationError.value = null;
  }

  async function reconcileAfterFailure(
    currentParentId: number,
    desiredDraft: ManagedSecretDraftItem[],
    originalIds: Set<number>,
    createdDraftIds: Set<number>,
    updatedIds: Set<number>,
    expectedSessionVersion: number
  ) {
    try {
      const response = await listManagedSecrets(params.parent, currentParentId);
      const serverSecrets = normalizeSecrets(response.secrets);
      cacheSnapshot(currentParentId, serverSecrets);
      if (sessionVersion !== expectedSessionVersion || activeParentId.value !== currentParentId) return;

      const desiredById = new Map(
        desiredDraft.filter((secret) => secret.id > 0).map((secret) => [secret.id, secret])
      );
      const reconciled = serverSecrets.flatMap<ManagedSecretDraftItem>((serverSecret) => {
        const desired = desiredById.get(serverSecret.id);
        if (desired) return [updatedIds.has(serverSecret.id) ? { ...serverSecret } : cloneDraft(desired)];
        return originalIds.has(serverSecret.id) ? [] : [{ ...serverSecret }];
      });
      reconciled.push(
        ...desiredDraft
          .filter((secret) => secret.id < 0 && !createdDraftIds.has(secret.id))
          .map(cloneDraft)
      );

      original.value = serverSecrets.map((secret) => ({ ...secret }));
      draft.value = reconciled;
      canonicalFingerprint = secretsFingerprint(serverSecrets);
      loaded.value = true;
    } catch (reloadError) {
      console.error(reloadError);
    }
  }

  async function sync(requestedParentId?: number | null) {
    const currentParentId = normalizeParentId(requestedParentId ?? activeParentId.value);
    if (!currentParentId || !loaded.value || !dirty.value) return;
    if (activeParentId.value === null) activeParentId.value = currentParentId;

    const syncSessionVersion = sessionVersion;
    const originalSnapshot = original.value.map((secret) => ({ ...secret }));
    const draftSnapshot = draft.value.map(cloneDraft);
    const draftById = new Map(
      draftSnapshot.filter((secret) => secret.id > 0).map((secret) => [secret.id, secret])
    );
    const originalById = new Map(originalSnapshot.map((secret) => [secret.id, secret]));
    const removed = originalSnapshot.filter((secret) => !draftById.has(secret.id));
    const changed = draftSnapshot.filter((secret) => {
      if (secret.id <= 0) return false;
      const persisted = originalById.get(secret.id);
      if (!persisted) return false;
      return (
        persisted.name !== secret.name ||
        persisted.description !== secret.description ||
        persisted.env_name !== secret.env_name ||
        Boolean(secret.value)
      );
    });
    const pending = draftSnapshot.filter((secret) => secret.id < 0);
    const originalIds = new Set(originalSnapshot.map((secret) => secret.id));
    const createdDraftIds = new Set<number>();
    const updatedIds = new Set<number>();

    syncing.value = true;
    operationError.value = null;

    try {
      let latestSecrets: ManagedSecretAttachment[] | null = null;

      for (const secret of removed) {
        const response = await deleteManagedSecret(params.parent, currentParentId, secret.id);
        latestSecrets = normalizeSecrets(response.secrets);
        cacheSnapshot(currentParentId, latestSecrets);
      }

      for (const secret of changed) {
        const response = await updateManagedSecret(params.parent, currentParentId, secret.id, {
          name: secret.name,
          description: secret.description,
          env_name: secret.env_name,
          ...(secret.value ? { value: secret.value } : {}),
        });
        updatedIds.add(secret.id);
        latestSecrets = normalizeSecrets(response.secrets);
        cacheSnapshot(currentParentId, latestSecrets);
      }

      for (const secret of pending) {
        if (!secret.value) throw new Error('A new managed secret is missing its value.');
        const response = await createManagedSecret(params.parent, currentParentId, {
          name: secret.name,
          description: secret.description,
          env_name: secret.env_name,
          value: secret.value,
        });
        createdDraftIds.add(secret.id);
        latestSecrets = normalizeSecrets(response.secrets);
        cacheSnapshot(currentParentId, latestSecrets);
      }

      if (!latestSecrets) {
        const response = await listManagedSecrets(params.parent, currentParentId);
        latestSecrets = normalizeSecrets(response.secrets);
        cacheSnapshot(currentParentId, latestSecrets);
      }

      if (sessionVersion === syncSessionVersion && activeParentId.value === currentParentId) {
        applyCanonicalSecrets(latestSecrets);
      }
    } catch (syncError) {
      console.error(syncError);
      if (sessionVersion === syncSessionVersion) {
        operationError.value = getApiErrorMessage(
          syncError,
          translate('Failed to save secret changes.')
        );
      }
      await reconcileAfterFailure(
        currentParentId,
        draftSnapshot,
        originalIds,
        createdDraftIds,
        updatedIds,
        syncSessionVersion
      );
      throw syncError;
    } finally {
      syncing.value = false;
      applyQuerySnapshot(query.data.value);
    }
  }

  return {
    original,
    secrets,
    loading,
    loaded,
    syncing,
    error,
    dirty,
    replaceSecrets,
    reset,
    sync,
  };
}
