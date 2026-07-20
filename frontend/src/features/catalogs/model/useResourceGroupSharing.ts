import { computed, ref, type ComputedRef } from 'vue';
import { useQuery } from '@tanstack/vue-query';

import { api } from '@/api/client';
import { toIntId } from '@/api/jsonApi';
import { serverStateKeys, serverStateQueryClient } from '@/features/serverState/queryClient';
import type { Group } from '@/types/api';

type ShareState = {
  group_ids?: number[];
};

type ResourceGroupSharingOptions = {
  resourceKey: string;
  resourceId: ComputedRef<number | null | undefined>;
  endpoint: (resourceId: number) => string;
  enabled: ComputedRef<boolean>;
  fallbackShared: ComputedRef<boolean>;
};

export function useResourceGroupSharing(options: ResourceGroupSharingOptions) {
  const modalOpen = ref(false);
  const saving = ref(false);
  const groups = ref<Group[]>([]);
  const selectedGroupIds = ref<number[]>([]);

  const groupsQuery = useQuery<Group[]>({
    queryKey: serverStateKeys.reference('user-groups', 'share-picker'),
    queryFn: async ({ signal }) => {
      const payload = await api.get<{ groups: Group[] }>('/api/bff/me/groups', { signal });
      return Array.isArray(payload.groups) ? payload.groups : [];
    },
  });

  const sharesQueryKey = computed(() =>
    serverStateKeys.detail(
      options.resourceKey,
      options.resourceId.value ?? 'new',
      'share-modal'
    )
  );

  const sharesQuery = useQuery<ShareState>({
    queryKey: sharesQueryKey,
    enabled: options.enabled,
    queryFn: ({ queryKey, signal }) => {
      const resourceId = toIntId(String(queryKey[3] ?? ''));
      if (!resourceId) throw new Error('Invalid resource id.');
      return api.get<ShareState>(options.endpoint(resourceId), { signal });
    },
  });

  const hasOutgoingShares = computed(() => {
    const groupIds = sharesQuery.data.value?.group_ids;
    return Array.isArray(groupIds) ? groupIds.length > 0 : options.fallbackShared.value;
  });

  const loading = computed(
    () => groupsQuery.isFetching.value || sharesQuery.isFetching.value
  );

  async function loadContext() {
    const requestedId = options.resourceId.value;
    if (!requestedId || !options.enabled.value) return;

    try {
      const [groupsResult, sharesResult] = await Promise.all([
        groupsQuery.refetch({ cancelRefetch: true }),
        sharesQuery.refetch({ cancelRefetch: true }),
      ]);
      if (options.resourceId.value !== requestedId) return;
      if (groupsResult.error) throw groupsResult.error;
      if (sharesResult.error) throw sharesResult.error;

      groups.value = groupsResult.data || [];
      selectedGroupIds.value = Array.isArray(sharesResult.data?.group_ids)
        ? sharesResult.data.group_ids.filter(
            (id): id is number => typeof id === 'number'
          )
        : [];
    } catch (error) {
      console.error(error);
      alert(error instanceof Error ? error.message : 'Failed to load sharing settings.');
    }
  }

  async function openModal() {
    await loadContext();
    modalOpen.value = true;
  }

  async function save(groupIds: number[]) {
    const resourceId = options.resourceId.value;
    if (!resourceId) return;

    saving.value = true;
    try {
      const response = await api.put<ShareState>(options.endpoint(resourceId), {
        group_ids: groupIds,
      });

      selectedGroupIds.value = Array.isArray(response.group_ids)
        ? response.group_ids.filter((id): id is number => typeof id === 'number')
        : [];
      serverStateQueryClient.setQueryData(sharesQueryKey.value, response);
      modalOpen.value = false;
    } catch (error) {
      console.error(error);
      alert(error instanceof Error ? error.message : 'Failed to save sharing settings.');
    } finally {
      saving.value = false;
    }
  }

  return {
    groups,
    hasOutgoingShares,
    loading,
    modalOpen,
    openModal,
    save,
    saving,
    selectedGroupIds,
  };
}
