const serverStateMocks = vi.hoisted(() => ({
  invalidate: vi.fn(),
}));

vi.mock('@/features/serverState/queryClient', () => ({
  invalidateServerStateQueries: serverStateMocks.invalidate,
}));

import { api } from '@/api/client';

function response(body: unknown = { ok: true }, status = 200) {
  return new Response(status === 204 ? null : JSON.stringify(body), {
    status,
    headers: status === 204 ? undefined : { 'content-type': 'application/json' },
  });
}

describe('API server-state invalidation', () => {
  const fetchMock = vi.fn();

  beforeEach(() => {
    fetchMock.mockReset();
    serverStateMocks.invalidate.mockReset();
    serverStateMocks.invalidate.mockResolvedValue(undefined);
    vi.stubGlobal('fetch', fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    document.getElementById('spa-root')?.remove();
    document.querySelector('meta[name="csrf-token"]')?.remove();
  });

  it('does not invalidate server state after GET', async () => {
    fetchMock.mockResolvedValueOnce(response());

    await api.get('/api/test');

    expect(serverStateMocks.invalidate).not.toHaveBeenCalled();
  });

  it.each([
    ['POST', () => api.post('/api/test', { name: 'new' })],
    ['PUT', () => api.put('/api/test/1', { name: 'replacement' })],
    ['PATCH', () => api.patch('/api/test/1', { name: 'updated' })],
    ['DELETE', () => api.del('/api/test/1')],
  ])('invalidates server state after %s', async (_method, request) => {
    fetchMock.mockResolvedValueOnce(response());

    await request();

    expect(serverStateMocks.invalidate).toHaveBeenCalledTimes(1);
  });

  it('invalidates server state after a successful 204 response', async () => {
    fetchMock.mockResolvedValueOnce(response(undefined, 204));

    await api.del('/api/test/1');

    expect(serverStateMocks.invalidate).toHaveBeenCalledTimes(1);
  });

  it('allows semantic read-only POST requests to opt out', async () => {
    fetchMock.mockResolvedValueOnce(response());

    await api.post('/api/test/preview', { source: 'draft' }, { invalidateServerState: false });

    expect(serverStateMocks.invalidate).not.toHaveBeenCalled();
  });

  it('bootstraps CSRF before a write from the neutral app shell', async () => {
    const root = document.createElement('div');
    root.id = 'spa-root';
    root.dataset.sessionBootstrap = 'required';
    document.body.append(root);
    fetchMock
      .mockResolvedValueOnce(
        response({ user: null, csrf_token: 'fresh-csrf-token' })
      )
      .mockResolvedValueOnce(response());

    await api.post('/api/test', { name: 'new' });

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      '/api/bff/auth/bootstrap',
      expect.objectContaining({
        cache: 'no-store',
        credentials: 'same-origin',
      })
    );
    const writeOptions = fetchMock.mock.calls[1]?.[1] as RequestInit;
    expect(new Headers(writeOptions.headers).get('x-csrf-token')).toBe(
      'fresh-csrf-token'
    );
  });

  it('waits for active server-state refresh before resolving a write', async () => {
    let releaseRefresh!: () => void;
    serverStateMocks.invalidate.mockImplementationOnce(
      () => new Promise<void>((resolve) => {
        releaseRefresh = resolve;
      })
    );
    fetchMock.mockResolvedValueOnce(response());

    let settled = false;
    const request = api.patch('/api/test/1', { name: 'updated' }).finally(() => {
      settled = true;
    });

    await vi.waitFor(() => expect(serverStateMocks.invalidate).toHaveBeenCalledTimes(1));
    expect(settled).toBe(false);

    releaseRefresh();
    await request;
    expect(settled).toBe(true);
  });
});
