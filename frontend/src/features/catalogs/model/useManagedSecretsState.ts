import { computed, toValue, type MaybeRefOrGetter } from 'vue';
import { useQuery } from '@tanstack/vue-query';

import { getApiErrorMessage } from '@/api/client';
import {
  listManagedSecrets,
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

function managedSecretsQueryKey(parent: SecretAttachmentParent, parentId: number | 'new') {
  return serverStateKeys.detail(parent, parentId, 'managed-secrets');
}

function normalizeParentId(value: number | null | undefined) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : null;
}

export function useManagedSecretsState(params: {
  parent: SecretAttachmentParent;
  parentId: MaybeRefOrGetter<number | null | undefined>;
  enabled?: MaybeRefOrGetter<boolean>;
}) {
  const parentId = computed(() => normalizeParentId(toValue(params.parentId)));
  const enabled = computed(
    () => parentId.value !== null && (params.enabled === undefined || toValue(params.enabled))
  );

  const query = useQuery<ManagedSecretsSnapshot>({
    queryKey: computed(() => managedSecretsQueryKey(params.parent, parentId.value ?? 'new')),
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

  const secrets = computed(() => {
    const snapshot = query.data.value;
    if (!snapshot || snapshot.parent !== params.parent || snapshot.parentId !== parentId.value) return [];
    return snapshot.secrets;
  });
  const loading = computed(() => enabled.value && !query.data.value && query.isPending.value);
  const error = computed(() => {
    if (query.data.value || !query.error.value) return null;
    return getApiErrorMessage(query.error.value, translate('Failed to load managed secrets.'));
  });

  function replaceSecrets(nextSecrets: ManagedSecretAttachment[]) {
    const currentParentId = parentId.value;
    if (!currentParentId) return;

    serverStateQueryClient.setQueryData<ManagedSecretsSnapshot>(
      managedSecretsQueryKey(params.parent, currentParentId),
      {
        parent: params.parent,
        parentId: currentParentId,
        secrets: nextSecrets || [],
      }
    );
  }

  return {
    secrets,
    loading,
    error,
    replaceSecrets,
  };
}
