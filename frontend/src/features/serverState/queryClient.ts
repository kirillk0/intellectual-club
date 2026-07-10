import { QueryClient, type QueryKey } from '@tanstack/vue-query';

export const SERVER_STATE_QUERY_ROOT = ['server-state'] as const;

type QueryIdentity = string | number | boolean | null | undefined | Record<string, unknown>;

export const serverStateKeys = {
  all: SERVER_STATE_QUERY_ROOT,
  collection(resource: string, projection = 'default', identity?: QueryIdentity): QueryKey {
    return [...SERVER_STATE_QUERY_ROOT, resource, 'collection', projection, identity ?? null];
  },
  detail(resource: string, id: string | number, projection = 'default'): QueryKey {
    return [...SERVER_STATE_QUERY_ROOT, resource, 'detail', String(id), projection];
  },
  reference(resource: string, projection = 'default', identity?: QueryIdentity): QueryKey {
    return [...SERVER_STATE_QUERY_ROOT, resource, 'reference', projection, identity ?? null];
  },
} as const;

export const serverStateQueryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 0,
      gcTime: 5 * 60 * 1000,
      retry: false,
      refetchOnMount: true,
      refetchOnWindowFocus: true,
      refetchOnReconnect: true,
      structuralSharing: true,
    },
  },
});

export async function invalidateServerStateQueries() {
  try {
    await serverStateQueryClient.invalidateQueries(
      {
        queryKey: SERVER_STATE_QUERY_ROOT,
        refetchType: 'active',
      },
      {
        cancelRefetch: true,
        throwOnError: false,
      }
    );
  } catch (error) {
    // The write already succeeded. Keep queries stale so a later layer reveal,
    // focus, or reconnect can retry without turning the mutation into a failure.
    console.warn('Failed to refresh server state after a successful write.', error);
  }
}

export function clearServerStateQueries() {
  serverStateQueryClient.clear();
}
