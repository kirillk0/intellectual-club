import { api } from '@/api/client';

const abortError = () => new DOMException('The operation was aborted.', 'AbortError');

function stalledResponse(
  signal: AbortSignal,
  onBodyStart: () => void,
  response: { ok?: boolean; status?: number; statusText?: string } = {}
): Response {
  return {
    ok: response.ok ?? true,
    status: response.status ?? 200,
    statusText: response.statusText ?? 'OK',
    text: () => {
      onBodyStart();
      return new Promise<string>((_resolve, reject) => {
        if (signal.aborted) {
          reject(abortError());
          return;
        }

        signal.addEventListener('abort', () => reject(abortError()), { once: true });
      });
    },
  } as Response;
}

describe('API response timeout', () => {
  const fetchMock = vi.fn();

  beforeEach(() => {
    vi.useFakeTimers();
    fetchMock.mockReset();
    vi.stubGlobal('fetch', fetchMock);
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('times out while reading a response body after headers arrive', async () => {
    let notifyBodyStarted!: () => void;
    const bodyStarted = new Promise<void>((resolve) => {
      notifyBodyStarted = resolve;
    });

    fetchMock.mockImplementation((_path: string, options: RequestInit) =>
      Promise.resolve(stalledResponse(options.signal as AbortSignal, notifyBodyStarted))
    );

    const outcome = api
      .get('/api/test', { timeoutMs: 100, retry: false, showErrorBanner: false })
      .then(
        () => null,
        (error: unknown) => error
      );

    await bodyStarted;
    await vi.advanceTimersByTimeAsync(100);

    const error = await outcome;
    expect(error).toBeInstanceOf(Error);
    expect((error as Error).name).toBe('RequestTimeoutError');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('retries after a response body timeout', async () => {
    let bodyStartCount = 0;
    let notifyFirstBodyStarted!: () => void;
    const firstBodyStarted = new Promise<void>((resolve) => {
      notifyFirstBodyStarted = resolve;
    });

    fetchMock.mockImplementation((_path: string, options: RequestInit) =>
      Promise.resolve(
        stalledResponse(options.signal as AbortSignal, () => {
          bodyStartCount += 1;
          if (bodyStartCount === 1) notifyFirstBodyStarted();
        })
      )
    );

    const outcome = api
      .get('/api/test', {
        timeoutMs: 50,
        retry: { attempts: 1, delaysMs: [0] },
        showErrorBanner: false,
      })
      .then(
        () => null,
        (error: unknown) => error
      );

    await firstBodyStarted;
    await vi.advanceTimersByTimeAsync(150);

    const error = await outcome;
    expect(error).toBeInstanceOf(Error);
    expect((error as Error).name).toBe('RequestTimeoutError');
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(bodyStartCount).toBe(2);
  });

  it('propagates an external abort while reading the response body without retrying', async () => {
    const controller = new AbortController();
    let notifyBodyStarted!: () => void;
    const bodyStarted = new Promise<void>((resolve) => {
      notifyBodyStarted = resolve;
    });

    fetchMock.mockImplementation((_path: string, options: RequestInit) =>
      Promise.resolve(stalledResponse(options.signal as AbortSignal, notifyBodyStarted))
    );

    const outcome = api
      .get('/api/test', {
        signal: controller.signal,
        timeoutMs: 1_000,
        retry: { attempts: 2, delaysMs: [0] },
        showErrorBanner: false,
      })
      .then(
        () => null,
        (error: unknown) => error
      );

    await bodyStarted;
    controller.abort();

    const error = await outcome;
    expect(error).toBeInstanceOf(DOMException);
    expect((error as DOMException).name).toBe('AbortError');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('preserves an HTTP error status when its response body times out', async () => {
    let notifyBodyStarted!: () => void;
    const bodyStarted = new Promise<void>((resolve) => {
      notifyBodyStarted = resolve;
    });

    fetchMock.mockImplementation((_path: string, options: RequestInit) =>
      Promise.resolve(
        stalledResponse(options.signal as AbortSignal, notifyBodyStarted, {
          ok: false,
          status: 404,
          statusText: 'Not Found',
        })
      )
    );

    const outcome = api
      .get('/api/test', {
        timeoutMs: 100,
        retry: { attempts: 2, delaysMs: [0] },
        showErrorBanner: false,
      })
      .then(
        () => null,
        (error: unknown) => error
      );

    await bodyStarted;
    await vi.advanceTimersByTimeAsync(100);

    const error = await outcome;
    expect(error).toMatchObject({
      name: 'HttpError',
      status: 404,
      statusText: 'Not Found',
      bodyText: '',
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});
