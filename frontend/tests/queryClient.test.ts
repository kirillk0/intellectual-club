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

  it('retries only transient reads and honors Retry-After', () => {
    const options = serverStateQueryClient.getDefaultOptions().queries;
    const retry = options?.retry as (failureCount: number, error: unknown) => boolean;
    const retryDelay = options?.retryDelay as (
      failureCount: number,
      error: unknown
    ) => number;

    expect(retry(0, new TypeError('Failed to fetch'))).toBe(true);
    expect(retry(0, { name: 'HttpError', status: 503 })).toBe(true);
    expect(retry(0, { name: 'HttpError', status: 404 })).toBe(false);
    expect(retry(0, new Error('Programming error'))).toBe(false);
    expect(
      retryDelay(0, {
        name: 'HttpError',
        status: 503,
        retryAfter: '4',
      })
    ).toBe(4_000);
    expect(options?.networkMode).toBe('always');
  });
});
