import { HttpError } from '@/api/client';
import {
  createRecoverableRead,
  type RecoverableReadController,
} from '@/features/app/useRecoverableRead';
import {
  isTransientReadError,
  retryAfterDelayMs,
} from '@/features/app/recoverableReadPolicy';
import { requestRecoveryNow } from '@/features/app/recoveryHeartbeat';

const controllers: RecoverableReadController<unknown>[] = [];

const createController = <T>() => {
  const controller = createRecoverableRead<T>({
    key: 'test-read',
  });
  controllers.push(controller as RecoverableReadController<unknown>);
  return controller;
};

describe('recoverable reads', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.spyOn(Math, 'random').mockReturnValue(0.5);
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true);
    vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible');
  });

  afterEach(() => {
    controllers.splice(0).forEach((controller) => controller.dispose());
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  it('keeps one promise and retries transient failures with the shared schedule', async () => {
    const controller = createController<string>();
    const read = vi
      .fn<() => Promise<string>>()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockRejectedValueOnce(new TypeError('Temporary failure'))
      .mockResolvedValue('ready');

    const first = controller.run(read);
    const second = controller.run(read);
    expect(second).toBe(first);

    await vi.waitFor(() => expect(read).toHaveBeenCalledTimes(1));
    await vi.advanceTimersByTimeAsync(500);
    expect(read).toHaveBeenCalledTimes(2);

    await vi.advanceTimersByTimeAsync(1_500);
    await expect(first).resolves.toBe('ready');
    expect(read).toHaveBeenCalledTimes(3);
  });

  it('shares one execution across controllers with the same key', async () => {
    let resolveRead!: (value: string) => void;
    let sharedSignal: AbortSignal | null = null;
    const first = createController<string>();
    const second = createController<string>();
    const firstRead = vi.fn(({ signal }: { signal: AbortSignal }) => {
      sharedSignal = signal;
      return new Promise<string>((resolve) => {
        resolveRead = resolve;
      });
    });
    const secondRead = vi.fn().mockResolvedValue('unexpected');

    const firstPromise = first.run(firstRead);
    const secondPromise = second.run(secondRead);

    expect(secondPromise).toBe(firstPromise);
    await vi.waitFor(() => expect(firstRead).toHaveBeenCalledTimes(1));
    expect(secondRead).not.toHaveBeenCalled();

    first.cancel();
    expect((sharedSignal as unknown as AbortSignal).aborted).toBe(false);
    resolveRead('ready');

    await expect(secondPromise).resolves.toBe('ready');
    expect(firstRead).toHaveBeenCalledTimes(1);
  });

  it('cancels the active request and does not retry it', async () => {
    const controller = createController<string>();
    const read = vi.fn(({ signal }: { signal: AbortSignal }) =>
      new Promise<string>((_resolve, reject) => {
        signal.addEventListener(
          'abort',
          () => reject(new DOMException('Aborted', 'AbortError')),
          { once: true }
        );
      })
    );

    const result = controller.run(read);
    await Promise.resolve();
    await Promise.resolve();
    expect(read).toHaveBeenCalledTimes(1);
    controller.cancel();

    await expect(result).rejects.toMatchObject({ name: 'AbortError' });
    await vi.runAllTimersAsync();
    expect(read).toHaveBeenCalledTimes(1);
  });

  it('attempts a real read even when navigator reports offline', async () => {
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false);
    const controller = createController<string>();
    const read = vi.fn().mockResolvedValue('ready');

    const result = controller.run(read);
    await expect(result).resolves.toBe('ready');
    expect(read).toHaveBeenCalledTimes(1);
  });

  it('keeps retry timers active while offline and hidden', async () => {
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false);
    vi
      .spyOn(document, 'visibilityState', 'get')
      .mockReturnValue('hidden');
    const controller = createController<string>();
    const read = vi
      .fn<() => Promise<string>>()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValue('ready');

    const result = controller.run(read);
    await vi.waitFor(() => expect(read).toHaveBeenCalledTimes(1));

    await vi.advanceTimersByTimeAsync(500);
    await expect(result).resolves.toBe('ready');
    expect(read).toHaveBeenCalledTimes(2);
  });

  it('uses a visible heartbeat to accelerate a scheduled retry', async () => {
    const controller = createController<string>();
    const read = vi
      .fn<() => Promise<string>>()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValue('ready');

    const result = controller.run(read);
    await vi.waitFor(() => expect(read).toHaveBeenCalledTimes(1));

    requestRecoveryNow();
    await expect(result).resolves.toBe('ready');
    expect(read).toHaveBeenCalledTimes(2);
  });

  it('does not retry terminal HTTP errors', async () => {
    const error = new HttpError({
      status: 404,
      statusText: 'Not Found',
      bodyText: '',
      bodyJson: null,
    });

    expect(isTransientReadError(error)).toBe(false);
    expect(isTransientReadError(new TypeError('Network error'))).toBe(true);
    expect(isTransientReadError(new Error('Programming error'))).toBe(false);
  });

  it('parses Retry-After seconds and HTTP dates with a 60 second cap', () => {
    const now = Date.parse('2026-07-17T10:00:00Z');

    expect(retryAfterDelayMs({ retryAfter: '4' }, now)).toBe(4_000);
    expect(
      retryAfterDelayMs({ retryAfter: 'Fri, 17 Jul 2026 10:00:12 GMT' }, now)
    ).toBe(12_000);
    expect(retryAfterDelayMs({ retryAfter: '300' }, now)).toBe(60_000);
    expect(retryAfterDelayMs({ retryAfter: 'invalid' }, now)).toBeNull();
  });

  it('honors Retry-After before retrying a transient HTTP response', async () => {
    const controller = createController<string>();
    const unavailable = new HttpError({
      status: 503,
      statusText: 'Service Unavailable',
      bodyText: '',
      bodyJson: null,
      retryAfter: '4',
    });
    const read = vi
      .fn<() => Promise<string>>()
      .mockRejectedValueOnce(unavailable)
      .mockResolvedValue('ready');

    const result = controller.run(read);
    await Promise.resolve();
    await Promise.resolve();
    expect(read).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(3_999);
    expect(read).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);

    await expect(result).resolves.toBe('ready');
    expect(read).toHaveBeenCalledTimes(2);
  });
});
