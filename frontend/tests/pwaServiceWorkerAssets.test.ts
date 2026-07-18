import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const repositoryRoot = path.resolve(import.meta.dirname, '../..');

describe('PWA static recovery assets', () => {
  it('keeps navigation network-only and activates upgrades only on request', () => {
    const source = fs.readFileSync(
      path.join(repositoryRoot, 'server/priv/static/service-worker.js'),
      'utf8'
    );
    const navigationHandler = source.slice(
      source.indexOf('const handleNavigation'),
      source.indexOf('const isRuntimeCacheableChunk')
    );
    const installHandler = source.slice(
      source.indexOf("self.addEventListener('install'"),
      source.indexOf("self.addEventListener('activate'")
    );

    expect(source).toContain("importScripts('/assets/pwa-precache-manifest.js')");
    expect(source).toContain('const NAVIGATION_TIMEOUT_MS = 3_000');
    expect(source).toContain("request.mode !== 'navigate'");
    expect(source).toContain("data.type === 'ACTIVATE_UPDATE'");
    expect(source).toContain("'/assets/code-version.json'");
    expect(source).toContain("'/assets/pwa-precache-manifest.js'");
    expect(source).toContain("request.headers.has('x-ic-recovery-probe')");
    expect(source).toContain('const COMPLETE_KEY');
    expect(navigationHandler).toContain('fetchWithTimeout(request, NAVIGATION_TIMEOUT_MS)');
    expect(navigationHandler).toContain('matchActiveCaches(OFFLINE_URL)');
    expect(navigationHandler).not.toContain('cache.put');
    expect(installHandler).not.toContain('skipWaiting');
  });

  it('uses a localized shell that probes health and the original URL before guarded reload', () => {
    const source = fs.readFileSync(
      path.join(repositoryRoot, 'server/priv/static/pwa/offline.html'),
      'utf8'
    );
    const healthProbe = source.indexOf('fetchWithTimeout("/health"');
    const navigationProbe = source.indexOf('fetchWithTimeout(targetUrl');
    const reload = source.indexOf('window.location.reload()');

    expect(source).toContain('Соединение прервано');
    expect(source).toContain('Connection interrupted');
    expect(source).toContain('window.sessionStorage');
    expect(source).toContain('window.history.replaceState');
    expect(source).toContain('memoryReloadGuard');
    expect(source).toContain('activeProbeController?.abort()');
    expect(source).toContain('if (!isDocumentVisible()) return');
    expect(source).toContain('const probeTimeoutMs = 2_500');
    expect(source).toContain('"X-IC-Recovery-Probe": "1"');
    expect(source).toContain('new URL("/assets/code-version.json"');
    expect(source).not.toContain('window.localStorage');
    expect(source).not.toContain('url: targetUrl');
    expect(source).not.toContain('<button');
    expect(healthProbe).toBeGreaterThan(0);
    expect(navigationProbe).toBeGreaterThan(healthProbe);
    expect(reload).toBeGreaterThan(navigationProbe);
  });

  it('includes route static closures without following nested dynamic payloads', async () => {
    const graphModulePath = '../scripts/pwa-bundle-graph.mjs';
    const { buildPwaBundleDescriptor } = await import(graphModulePath);
    const chunk = (
      fileName: string,
      options: {
        entry?: boolean;
        dynamic?: boolean;
        facade?: string;
        imports?: string[];
        dynamicImports?: string[];
      } = {}
    ) => ({
      type: 'chunk',
      fileName,
      code: '',
      isEntry: options.entry === true,
      isDynamicEntry: options.dynamic === true,
      facadeModuleId: options.facade || null,
      imports: options.imports || [],
      dynamicImports: options.dynamicImports || [],
      viteMetadata: { importedAssets: new Set<string>() },
    });
    const routeView = chunk('js/chunks/RouteView.js', {
      dynamic: true,
      facade: '/repo/frontend/src/views/RouteView.vue',
      imports: ['js/chunks/route-shared.js'],
      dynamicImports: ['js/chunks/NestedView.js', 'js/chunks/MarkdownCodeViewer.js'],
    });
    routeView.viteMetadata.importedAssets.add('temml.min.js');
    const descriptor = buildPwaBundleDescriptor({
      'js/spa.js': chunk('js/spa.js', {
        entry: true,
        imports: ['js/chunks/shared.js'],
        dynamicImports: [
          'js/chunks/RouteView.js',
          'js/chunks/JsonCodeEditor.js',
          'js/chunks/prism-rust.js',
        ],
      }),
      'js/chunks/shared.js': chunk('js/chunks/shared.js'),
      'js/chunks/RouteView.js': routeView,
      'js/chunks/route-shared.js': chunk('js/chunks/route-shared.js'),
      'js/chunks/NestedView.js': chunk('js/chunks/NestedView.js', {
        dynamic: true,
        facade: '/repo/frontend/src/views/NestedView.vue',
      }),
      'js/chunks/JsonCodeEditor.js': chunk('js/chunks/JsonCodeEditor.js', {
        dynamic: true,
        facade: '/repo/frontend/src/features/catalogs/components/JsonCodeEditor.vue',
      }),
      'js/chunks/MarkdownCodeViewer.js': chunk('js/chunks/MarkdownCodeViewer.js', {
        dynamic: true,
        facade: '/repo/frontend/src/components/MarkdownCodeViewer.vue',
      }),
      'js/chunks/prism-rust.js': chunk('js/chunks/prism-rust.js', {
        dynamic: true,
        facade: '/repo/frontend/node_modules/prismjs/components/prism-rust.js',
      }),
    });

    expect(descriptor.precache).toEqual([
      'js/spa.js',
      'js/chunks/RouteView.js',
      'js/chunks/route-shared.js',
      'js/chunks/shared.js',
      'css/spa.css',
    ]);
    expect(descriptor.precache).not.toContain('temml.min.js');
  });

  it('rejects oversized entries and inline raster payloads', async () => {
    const graphModulePath = '../scripts/pwa-bundle-graph.mjs';
    const { CRITICAL_ENTRY_MAX_BYTES, validateCriticalEntry } = await import(graphModulePath);
    const bundleWithCode = (code: string) => ({
      'js/spa.js': {
        type: 'chunk',
        fileName: 'js/spa.js',
        code,
        isEntry: true,
        imports: [],
      },
    });

    expect(() =>
      validateCriticalEntry(bundleWithCode('x'.repeat(CRITICAL_ENTRY_MAX_BYTES + 1)))
    ).toThrow(/limit/u);
    expect(() =>
      validateCriticalEntry(bundleWithCode('const icon = "data:image/png;base64,AAAA";'))
    ).toThrow(/base64 raster/u);
    expect(validateCriticalEntry(bundleWithCode('const ready = true;')).size).toBe(19);

    expect(() =>
      validateCriticalEntry({
        'js/spa.js': {
          type: 'chunk',
          fileName: 'js/spa.js',
          code: 'import "./chunks/shared.js";',
          isEntry: true,
          imports: ['js/chunks/shared.js'],
        },
        'js/chunks/shared.js': {
          type: 'chunk',
          fileName: 'js/chunks/shared.js',
          code: 'x'.repeat(CRITICAL_ENTRY_MAX_BYTES),
          isEntry: false,
          imports: [],
        },
      })
    ).toThrow(/critical static closure/u);
    expect(() =>
      validateCriticalEntry({
        'js/spa.js': {
          type: 'chunk',
          fileName: 'js/spa.js',
          code: 'import "./chunks/shared.js";',
          isEntry: true,
          imports: ['js/chunks/shared.js'],
        },
        'js/chunks/shared.js': {
          type: 'chunk',
          fileName: 'js/chunks/shared.js',
          code: 'const image = "data:image/webp;base64,AAAA";',
          isEntry: false,
          imports: [],
        },
      })
    ).toThrow(/base64 raster/u);
  });

  it('keeps the offline reload guard non-sensitive and scoped to a build', async () => {
    const source = fs.readFileSync(
      path.join(repositoryRoot, 'server/priv/static/pwa/offline.html'),
      'utf8'
    );
    const script = source.match(/<script>([\s\S]*?)<\/script>/u)?.[1];
    if (!script) throw new Error('Offline shell recovery script is missing.');

    let buildId = 'build-a';
    let timerId = 0;
    const targetUrl = 'https://club.test/chats/42?filter=private-value';
    const stored = new Map<string, string>();
    const reload = vi.fn();
    const history = {
      state: null as Record<string, unknown> | null,
      replaceState(nextState: Record<string, unknown>) {
        this.state = nextState;
      },
    };
    const sessionStorage = {
      getItem: (key: string) => stored.get(key) ?? null,
      setItem: (key: string, value: string) => stored.set(key, value),
      removeItem: (key: string) => stored.delete(key),
    };
    const windowMock = {
      location: { href: targetUrl, origin: 'https://club.test', reload },
      history,
      sessionStorage,
      setTimeout: vi.fn(() => {
        timerId += 1;
        return timerId;
      }),
      clearTimeout: vi.fn(),
      addEventListener: vi.fn(),
    };
    const element = {
      textContent: '',
      setAttribute: vi.fn(),
    };
    const documentMock = {
      visibilityState: 'visible',
      documentElement: { lang: 'en' },
      getElementById: vi.fn(() => element),
      querySelector: vi.fn(() => element),
      addEventListener: vi.fn(),
    };
    const fetchMock = vi.fn((input: RequestInfo | URL) => {
      const url = new URL(String(input), targetUrl);
      if (url.pathname === '/assets/code-version.json') {
        return Promise.resolve(
          new Response(JSON.stringify({ label: buildId }), {
            status: 200,
            headers: { 'content-type': 'application/json' },
          })
        );
      }
      return Promise.resolve(new Response(null, { status: 204 }));
    });
    const context = {
      window: windowMock,
      document: documentMock,
      navigator: { language: 'en' },
      fetch: fetchMock,
      AbortController,
      URL,
      Date,
      Object,
      JSON,
      Number,
      Error,
    };
    const flushProbe = async () => {
      for (let index = 0; index < 16; index += 1) await Promise.resolve();
    };

    vm.runInNewContext(script, context);
    await flushProbe();

    expect(reload).toHaveBeenCalledTimes(1);
    expect(stored.get('intellectual-club:pwa:offline-reload')).toBe('build-a');
    expect(JSON.stringify(history.state)).not.toContain(targetUrl);
    expect([...stored.values()].join(' ')).not.toContain(targetUrl);

    vm.runInNewContext(script, context);
    await flushProbe();
    expect(reload).toHaveBeenCalledTimes(1);

    buildId = 'build-b';
    vm.runInNewContext(script, context);
    await flushProbe();

    expect(reload).toHaveBeenCalledTimes(2);
    expect(stored.get('intellectual-club:pwa:offline-reload')).toBe('build-b');
  });

  it('aborts an active offline probe while hidden and resumes immediately when visible', async () => {
    const source = fs.readFileSync(
      path.join(repositoryRoot, 'server/priv/static/pwa/offline.html'),
      'utf8'
    );
    const script = source.match(/<script>([\s\S]*?)<\/script>/u)?.[1];
    if (!script) throw new Error('Offline shell recovery script is missing.');

    const originalVisibility = Object.getOwnPropertyDescriptor(document, 'visibilityState');
    const setVisibility = (value: 'visible' | 'hidden') => {
      Object.defineProperty(document, 'visibilityState', {
        configurable: true,
        value,
      });
    };
    const signals: AbortSignal[] = [];
    const fetchMock = vi.fn((_input: RequestInfo | URL, options?: RequestInit) => {
      const signal = options?.signal as AbortSignal;
      signals.push(signal);

      return new Promise<Response>((_resolve, reject) => {
        const rejectAbort = () =>
          reject(signal.reason || new DOMException('Probe aborted.', 'AbortError'));
        if (signal.aborted) {
          rejectAbort();
        } else {
          signal.addEventListener('abort', rejectAbort, { once: true });
        }
      });
    });

    vi.useFakeTimers();
    vi.stubGlobal('fetch', fetchMock);
    document.body.innerHTML = `
      <h1 id="offline-heading"></h1>
      <p id="offline-copy"></p>
      <div class="offline-progress"></div>
    `;
    setVisibility('visible');

    try {
      window.eval(script);
      await Promise.resolve();
      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(signals[0]?.aborted).toBe(false);

      setVisibility('hidden');
      document.dispatchEvent(new Event('visibilitychange'));
      await Promise.resolve();
      await Promise.resolve();

      expect(signals[0]?.aborted).toBe(true);
      expect(vi.getTimerCount()).toBe(0);

      setVisibility('visible');
      document.dispatchEvent(new Event('visibilitychange'));
      await Promise.resolve();

      expect(fetchMock).toHaveBeenCalledTimes(2);
      expect(signals[1]?.aborted).toBe(false);

      setVisibility('hidden');
      document.dispatchEvent(new Event('visibilitychange'));
      await Promise.resolve();
      await Promise.resolve();

      expect(signals[1]?.aborted).toBe(true);
      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.unstubAllGlobals();
      vi.useRealTimers();
      if (originalVisibility) {
        Object.defineProperty(document, 'visibilityState', originalVisibility);
      }
    }
  });
});
