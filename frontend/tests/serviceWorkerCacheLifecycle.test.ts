import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const repositoryRoot = path.resolve(import.meta.dirname, '../..');
const serviceWorkerSource = fs.readFileSync(
  path.join(repositoryRoot, 'server/priv/static/service-worker.js'),
  'utf8'
);
const origin = 'https://club.test';
const cachePrefix = 'intellectual-club:pwa:';
const metadataCacheName = `${cachePrefix}meta`;
const metadataKey = '/__pwa_cache_metadata__';
const completeKey = '/__pwa_cache_complete__';

class MemoryCache {
  readonly entries = new Map<string, Response>();

  private key(input: RequestInfo | URL) {
    const value = typeof input === 'string' || input instanceof URL ? String(input) : input.url;
    return new URL(value, origin).href;
  }

  async match(input: RequestInfo | URL, options?: { ignoreSearch?: boolean }) {
    const key = this.key(input);
    const direct = this.entries.get(key);
    if (direct) return direct.clone();

    if (options?.ignoreSearch) {
      const target = new URL(key);
      target.search = '';

      for (const [storedKey, response] of this.entries) {
        const stored = new URL(storedKey);
        stored.search = '';
        if (stored.href === target.href) return response.clone();
      }
    }

    return undefined;
  }

  async put(input: RequestInfo | URL, response: Response) {
    this.entries.set(this.key(input), response.clone());
  }
}

class MemoryCacheStorage {
  readonly stores = new Map<string, MemoryCache>();
  readonly deleted: string[] = [];

  async open(cacheName: string) {
    let cache = this.stores.get(cacheName);
    if (!cache) {
      cache = new MemoryCache();
      this.stores.set(cacheName, cache);
    }
    return cache;
  }

  async delete(cacheName: string) {
    this.deleted.push(cacheName);
    return this.stores.delete(cacheName);
  }

  async keys() {
    return [...this.stores.keys()];
  }

  async match(
    input: RequestInfo | URL,
    options?: { cacheName?: string; ignoreSearch?: boolean }
  ) {
    if (options?.cacheName) {
      return this.stores.get(options.cacheName)?.match(input, options);
    }

    for (const cache of this.stores.values()) {
      const response = await cache.match(input);
      if (response) return response;
    }

    return undefined;
  }
}

type WorkerManifest = {
  buildId: string;
  revision: string;
  mode: 'dev' | 'prod';
  offlineUrl: string;
  assets: string[];
};

const cacheName = (revision: string) => `${cachePrefix}assets:${revision}`;

const writeMetadata = async (
  cacheStorage: MemoryCacheStorage,
  current: string,
  previous: string | null
) => {
  const cache = await cacheStorage.open(metadataCacheName);
  await cache.put(
    metadataKey,
    new Response(JSON.stringify({ current, previous }), {
      headers: { 'content-type': 'application/json' },
    })
  );
};

const markComplete = async (
  cacheStorage: MemoryCacheStorage,
  revision: string,
  assets: string[]
) => {
  const cache = await cacheStorage.open(cacheName(revision));
  for (const asset of assets) {
    await cache.put(asset, new Response(asset));
  }
  await cache.put(completeKey, new Response(revision));
};

const createWorker = (
  manifest: WorkerManifest,
  cacheStorage: MemoryCacheStorage,
  fetchMock: ReturnType<typeof vi.fn>
) => {
  const listeners = new Map<string, (event: any) => void>();
  const claim = vi.fn().mockResolvedValue(undefined);
  const delays: number[] = [];
  const worker = {
    __PWA_PRECACHE_MANIFEST__: manifest,
    location: { origin },
    clients: {
      claim,
      matchAll: vi.fn().mockResolvedValue([]),
      openWindow: vi.fn(),
    },
    registration: {
      showNotification: vi.fn(),
      getNotifications: vi.fn().mockResolvedValue([]),
    },
    skipWaiting: vi.fn().mockResolvedValue(undefined),
    addEventListener: (type: string, listener: (event: any) => void) => {
      listeners.set(type, listener);
    },
  };

  vm.runInNewContext(serviceWorkerSource, {
    self: worker,
    caches: cacheStorage,
    fetch: fetchMock,
    importScripts: vi.fn(),
    Request,
    Response,
    URL,
    AbortController,
    DOMException,
    setTimeout: (callback: () => void, milliseconds = 0) => {
      delays.push(milliseconds);
      callback();
      return 1;
    },
    clearTimeout: vi.fn(),
    console,
  });

  const runLifecycleEvent = async (type: 'install' | 'activate') => {
    let task: Promise<unknown> | null = null;
    listeners.get(type)?.({
      waitUntil(promise: Promise<unknown>) {
        task = promise;
      },
    });
    if (!task) throw new Error(`${type} listener did not register a task.`);
    await task;
  };

  const runFetch = async (request: Request) => {
    const captured: { response?: Promise<Response> } = {};
    listeners.get('fetch')?.({
      request,
      respondWith(promise: Promise<Response>) {
        captured.response = promise;
      },
    });
    if (!captured.response) throw new Error('fetch listener did not handle the request.');
    return captured.response;
  };

  return { claim, delays, runFetch, runLifecycleEvent };
};

const manifest = (revision: string): WorkerManifest => ({
  buildId: '/assets/js/spa-digest.js?vsn=d',
  revision,
  mode: 'prod',
  offlineUrl: '/pwa/offline.html',
  assets: ['/assets/js/spa-digest.js?vsn=d', '/pwa/offline.html'],
});

describe('service worker cache lifecycle', () => {
  it.each([
    ['/api/private'],
    ['/auth/sign-in'],
    ['/assets/code-version.json'],
    ['/assets/js/app.js.map'],
    ['https://example.invalid/asset.js'],
  ])('rejects an unsafe precache URL before install: %s', (unsafeUrl) => {
    const storage = new MemoryCacheStorage();
    const unsafeManifest = manifest('unsafe-revision');
    unsafeManifest.assets.push(unsafeUrl);

    expect(() => createWorker(unsafeManifest, storage, vi.fn())).toThrow(
      'PWA precache manifest is missing or invalid.'
    );
    expect(storage.stores.size).toBe(0);
  });

  it('reuses a complete active cache when worker code changes without a build change', async () => {
    const storage = new MemoryCacheStorage();
    const currentManifest = manifest('current-revision');
    await markComplete(storage, currentManifest.revision, currentManifest.assets);
    await writeMetadata(storage, currentManifest.revision, null);
    const fetchMock = vi.fn();
    const worker = createWorker(currentManifest, storage, fetchMock);

    await worker.runLifecycleEvent('install');

    expect(fetchMock).not.toHaveBeenCalled();
    expect(storage.deleted).not.toContain(cacheName(currentManifest.revision));
    expect(storage.stores.has(cacheName(currentManifest.revision))).toBe(true);
  });

  it('repairs an evicted asset even when the completion marker remains', async () => {
    const storage = new MemoryCacheStorage();
    const currentManifest = manifest('current-revision');
    const cache = await storage.open(cacheName(currentManifest.revision));
    await cache.put(currentManifest.assets[0], new Response('entry'));
    await cache.put(completeKey, new Response(currentManifest.revision));
    await writeMetadata(storage, currentManifest.revision, null);
    const fetchMock = vi.fn().mockResolvedValue(new Response('restored'));
    const worker = createWorker(currentManifest, storage, fetchMock);

    await worker.runLifecycleEvent('install');

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(await cache.match(currentManifest.assets[1])).toBeDefined();
    expect(storage.deleted).not.toContain(cacheName(currentManifest.revision));
  });

  it('deletes only a failed new cache and preserves the active version', async () => {
    const storage = new MemoryCacheStorage();
    const oldManifest = manifest('old-revision');
    const newManifest = manifest('new-revision');
    await markComplete(storage, oldManifest.revision, oldManifest.assets);
    await writeMetadata(storage, oldManifest.revision, null);
    const worker = createWorker(
      newManifest,
      storage,
      vi.fn().mockRejectedValue(new Error('offline'))
    );

    await expect(worker.runLifecycleEvent('install')).rejects.toThrow('offline');

    expect(storage.stores.has(cacheName(oldManifest.revision))).toBe(true);
    expect(storage.stores.has(cacheName(newManifest.revision))).toBe(false);
    expect(storage.deleted).toContain(cacheName(newManifest.revision));
    expect(storage.deleted).not.toContain(cacheName(oldManifest.revision));
  });

  it('rotates current to previous and removes versions older than one generation', async () => {
    const storage = new MemoryCacheStorage();
    const newManifest = manifest('new-revision');
    await markComplete(storage, newManifest.revision, newManifest.assets);
    await markComplete(storage, 'old-revision', newManifest.assets);
    await markComplete(storage, 'older-revision', newManifest.assets);
    await writeMetadata(storage, 'old-revision', 'older-revision');
    const worker = createWorker(newManifest, storage, vi.fn());

    await worker.runLifecycleEvent('activate');

    const metadataResponse = await (
      await storage.open(metadataCacheName)
    ).match(metadataKey);
    expect(await metadataResponse?.json()).toEqual({
      current: 'new-revision',
      previous: 'old-revision',
    });
    expect(storage.stores.has(cacheName(newManifest.revision))).toBe(true);
    expect(storage.stores.has(cacheName('old-revision'))).toBe(true);
    expect(storage.stores.has(cacheName('older-revision'))).toBe(false);
    expect(worker.claim).toHaveBeenCalledTimes(1);
  });

  it('keeps retrying runtime chunks after network and retryable HTTP failures', async () => {
    const storage = new MemoryCacheStorage();
    const currentManifest = manifest('current-revision');
    await markComplete(storage, currentManifest.revision, currentManifest.assets);
    await writeMetadata(storage, currentManifest.revision, null);
    const fetchMock = vi
      .fn()
      .mockRejectedValueOnce(new Error('offline'))
      .mockResolvedValueOnce(new Response('retry', { status: 503 }))
      .mockResolvedValueOnce(new Response('loaded', { status: 200 }));
    const worker = createWorker(currentManifest, storage, fetchMock);

    const response = await worker.runFetch(
      new Request(`${origin}/assets/js/chunks/LazyView-abc123.js`)
    );

    expect(await response.text()).toBe('loaded');
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(worker.delays.filter((delay) => delay !== 10_000)).toEqual([500, 1_500]);
  });

  it('aborts a stalled runtime attempt before retrying the chunk', async () => {
    const storage = new MemoryCacheStorage();
    const currentManifest = manifest('current-revision');
    await markComplete(storage, currentManifest.revision, currentManifest.assets);
    await writeMetadata(storage, currentManifest.revision, null);
    let firstAttemptSignal: AbortSignal | undefined;
    const fetchMock = vi
      .fn()
      .mockImplementationOnce((_request, options: RequestInit) => {
        firstAttemptSignal = options.signal as AbortSignal;
        return Promise.reject(new DOMException('Timed out.', 'AbortError'));
      })
      .mockResolvedValueOnce(new Response('loaded', { status: 200 }));
    const worker = createWorker(currentManifest, storage, fetchMock);

    const response = await worker.runFetch(
      new Request(`${origin}/assets/js/chunks/StalledView-abc123.js`)
    );

    expect(await response.text()).toBe('loaded');
    expect(firstAttemptSignal?.aborted).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(worker.delays).toContain(10_000);
    expect(worker.delays.filter((delay) => delay !== 10_000)).toEqual([500]);
  });

  it('stops runtime recovery when the original request is aborted', async () => {
    const storage = new MemoryCacheStorage();
    const currentManifest = manifest('current-revision');
    await markComplete(storage, currentManifest.revision, currentManifest.assets);
    await writeMetadata(storage, currentManifest.revision, null);
    const controller = new AbortController();
    controller.abort(new DOMException('Navigation left.', 'AbortError'));
    const fetchMock = vi.fn((_request, options: RequestInit) => {
      expect((options.signal as AbortSignal).aborted).toBe(true);
      return Promise.reject(new DOMException('Navigation left.', 'AbortError'));
    });
    const worker = createWorker(currentManifest, storage, fetchMock);

    await expect(
      worker.runFetch(
        new Request(`${origin}/assets/js/chunks/CancelledView-abc123.js`, {
          signal: controller.signal,
        })
      )
    ).rejects.toMatchObject({ name: 'AbortError' });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(worker.delays.filter((delay) => delay !== 10_000)).toEqual([]);
  });

  it.each([408, 425, 429, 500, 599])(
    'retries runtime chunks after status %s',
    async (status) => {
      const storage = new MemoryCacheStorage();
      const currentManifest = manifest('current-revision');
      await markComplete(storage, currentManifest.revision, currentManifest.assets);
      await writeMetadata(storage, currentManifest.revision, null);
      const fetchMock = vi
        .fn()
        .mockResolvedValueOnce(new Response('retry', { status }))
        .mockResolvedValueOnce(new Response('loaded', { status: 200 }));
      const worker = createWorker(currentManifest, storage, fetchMock);

      const response = await worker.runFetch(
        new Request(`${origin}/assets/js/chunks/LazyView-abc123.js`)
      );

      expect(response.status).toBe(200);
      expect(fetchMock).toHaveBeenCalledTimes(2);
    }
  );

  it.each([404, 410])('treats runtime chunk status %s as terminal', async (status) => {
    const storage = new MemoryCacheStorage();
    const currentManifest = manifest('current-revision');
    await markComplete(storage, currentManifest.revision, currentManifest.assets);
    await writeMetadata(storage, currentManifest.revision, null);
    const fetchMock = vi.fn().mockResolvedValue(new Response('missing', { status }));
    const worker = createWorker(currentManifest, storage, fetchMock);

    const response = await worker.runFetch(
      new Request(`${origin}/assets/js/chunks/MissingView-abc123.js`)
    );

    expect(response.status).toBe(status);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('matches a precached development entry when the release copy changes its mtime query', async () => {
    const storage = new MemoryCacheStorage();
    const currentManifest: WorkerManifest = {
      buildId: '/assets/js/spa.js?v=100',
      revision: 'dev-revision',
      mode: 'dev',
      offlineUrl: '/pwa/offline.html',
      assets: ['/assets/js/spa.js?v=100', '/pwa/offline.html'],
    };
    await markComplete(storage, currentManifest.revision, currentManifest.assets);
    await writeMetadata(storage, currentManifest.revision, null);
    const fetchMock = vi.fn().mockRejectedValue(new Error('offline'));
    const worker = createWorker(currentManifest, storage, fetchMock);

    const response = await worker.runFetch(
      new Request(`${origin}/assets/js/spa.js?v=103`)
    );

    expect(await response.text()).toBe('/assets/js/spa.js?v=100');
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(worker.delays.filter((delay) => delay !== 10_000)).toEqual([]);
  });
});
