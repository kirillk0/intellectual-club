import {
  SERVER_STATE_QUERY_ROOT,
  invalidateServerStateQueries,
  serverStateQueryClient,
} from '@/features/serverState/queryClient';

describe('server-state query invalidation', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('invalidates the whole namespace and cancels superseded refreshes', async () => {
    const invalidate = vi
      .spyOn(serverStateQueryClient, 'invalidateQueries')
      .mockResolvedValue(undefined);

    await invalidateServerStateQueries();

    expect(invalidate).toHaveBeenCalledWith(
      { queryKey: SERVER_STATE_QUERY_ROOT, refetchType: 'active' },
      { cancelRefetch: true, throwOnError: false }
    );
  });

  it('does not turn a successful write into an error when refresh fails', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    vi.spyOn(serverStateQueryClient, 'invalidateQueries').mockRejectedValue(
      new Error('refresh failed')
    );

    await expect(invalidateServerStateQueries()).resolves.toBeUndefined();
  });
});
