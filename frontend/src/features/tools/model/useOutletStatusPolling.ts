import { computed, onBeforeUnmount, onMounted, ref, watch, type Ref } from 'vue';

import { api } from '@/api/client';

type OutletTool = {
  id: number;
  type: string;
  outlet_online?: boolean | null;
};

const POLL_INTERVAL_MS = 30_000;
const BATCH_SIZE = 200;

export function useOutletStatusPolling(params: {
  scopeId: Ref<number>;
  enabled: Ref<boolean>;
  tools: Ref<OutletTool[]>;
}) {
  const visible = ref(document.visibilityState === 'visible');
  const ids = computed(() => [...new Set(params.tools.value
    .filter((tool) => tool.type === 'outlet')
    .map((tool) => tool.id))].sort((a, b) => a - b).join(','));
  const requestKey = computed(() =>
    params.enabled.value && visible.value && ids.value
      ? `${params.scopeId.value}:${ids.value}`
      : ''
  );
  let timer: number | undefined;
  let controller: AbortController | undefined;
  let version = 0;

  const stop = () => {
    version += 1;
    window.clearTimeout(timer);
    timer = undefined;
    controller?.abort();
    controller = undefined;
  };

  const schedule = () => {
    const key = requestKey.value;
    if (!key) return;
    const currentVersion = version;
    timer = window.setTimeout(async () => {
      timer = undefined;
      const request = new AbortController();
      controller = request;
      const current = () => !request.signal.aborted && version === currentVersion && requestKey.value === key;

      try {
        const toolIds = ids.value.split(',');
        for (let offset = 0; offset < toolIds.length; offset += BATCH_SIZE) {
          const query = new URLSearchParams({ ids: toolIds.slice(offset, offset + BATCH_SIZE).join(',') });
          const payload = await api.get<{ tools: { id: number; outlet_online: boolean }[] }>(
            `/api/bff/tools/status?${query}`,
            { signal: request.signal, showErrorBanner: false, retry: false }
          );
          if (!current()) return;
          const statuses = new Map(payload.tools.map((tool) => [tool.id, tool.outlet_online]));
          for (const tool of params.tools.value) {
            const online = statuses.get(tool.id);
            if (tool.type === 'outlet' && typeof online === 'boolean') tool.outlet_online = online;
          }
        }
      } catch (error) {
        if (current()) console.warn('Failed to refresh outlet statuses.', error);
      } finally {
        if (controller === request) controller = undefined;
        if (current()) schedule();
      }
    }, POLL_INTERVAL_MS);
  };

  watch(requestKey, () => {
    stop();
    schedule();
  }, { immediate: true });

  const handleVisibilityChange = () => {
    visible.value = document.visibilityState === 'visible';
  };
  onMounted(() => document.addEventListener('visibilitychange', handleVisibilityChange));
  onBeforeUnmount(() => {
    stop();
    document.removeEventListener('visibilitychange', handleVisibilityChange);
  });
}
