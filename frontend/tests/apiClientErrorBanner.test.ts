import { api, isHttpError } from '@/api/client';
import {
  clearBackendStatusBanner,
  showBackendStatusBanner,
  useBackendStatusBanner,
} from '@/features/app/backendStatusBanner';

const SEARCH_PATH = '/api/bff/chat-list/search?q=needle';
const SEARCH_BANNER_KEY = 'GET:/api/bff/chat-list/search';

function jsonResponse(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

const isSearchTimeout = (error: unknown) =>
  isHttpError(error) && (error.bodyJson as { code?: unknown } | null)?.code === 'search_timeout';

describe('API error banner predicate', () => {
  const fetchMock = vi.fn();
  const { banner } = useBackendStatusBanner();

  beforeEach(() => {
    fetchMock.mockReset();
    vi.stubGlobal('fetch', fetchMock);
  });

  afterEach(() => {
    clearBackendStatusBanner(SEARCH_BANNER_KEY);
    vi.unstubAllGlobals();
  });

  it('lets the caller report a handled error inline without a banner or retry', async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: 'Search timed out.', code: 'search_timeout' }, 503));

    const error = await api
      .get(SEARCH_PATH, { showErrorBanner: (failure) => !isSearchTimeout(failure) })
      .catch((failure: unknown) => failure);

    expect(error).toMatchObject({ name: 'HttpError', status: 503, bodyJson: { code: 'search_timeout' } });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(banner.value).toBeNull();
  });

  it('keeps the banner for errors the predicate does not handle', async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: 'Database is down.' }, 503));

    await expect(api.get(SEARCH_PATH, { showErrorBanner: (failure) => !isSearchTimeout(failure) }))
      .rejects.toMatchObject({ status: 503 });

    expect(banner.value).toEqual({ title: 'Server error', message: 'Database is down.' });
  });

  it('clears a stale incident of the same request when the error is handled inline', async () => {
    showBackendStatusBanner({ title: 'Connection problem', message: 'Offline.' }, SEARCH_BANNER_KEY);
    fetchMock.mockResolvedValueOnce(jsonResponse({ error: 'Search timed out.', code: 'search_timeout' }, 503));

    await expect(api.get(SEARCH_PATH, { showErrorBanner: (failure) => !isSearchTimeout(failure) }))
      .rejects.toMatchObject({ status: 503 });

    expect(banner.value).toBeNull();
  });
});
