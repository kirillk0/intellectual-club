import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const repositoryRoot = path.resolve(import.meta.dirname, '../..');

describe('PWA static recovery assets', () => {
  it('serves fresh network navigation with cached recovery while activating upgrades only on request', () => {
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
    expect(source).toContain("const APP_SHELL_URL = '/pwa/app-shell'");
    expect(source).toContain("request.mode !== 'navigate'");
    expect(source).toContain("data.type === 'ACTIVATE_UPDATE'");
    expect(source).toContain("'/assets/code-version.json'");
    expect(source).toContain("'/assets/pwa-precache-manifest.js'");
    expect(source).toContain("request.headers.has('x-ic-recovery-probe')");
    expect(source).toContain('const COMPLETE_KEY');
    expect(navigationHandler).toContain('matchActiveCaches(APP_SHELL_URL)');
    expect(navigationHandler).toContain('return appShell');
    expect(navigationHandler).toContain('return await networkResponse');
    expect(navigationHandler).toContain('matchActiveCaches(OFFLINE_URL)');
    expect(navigationHandler).not.toContain('cache.put');
    expect(navigationHandler.indexOf('return await networkResponse')).toBeLessThan(
      navigationHandler.indexOf('matchActiveCaches(APP_SHELL_URL)')
    );
    expect(source).not.toContain('NAVIGATION_TIMEOUT_MS');
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
    expect(source).toContain('memoryReloadAt');
    expect(source).toContain('const reloadGuardWindowMs = 15_000');
    expect(source).toContain('const probeTimeoutMs = 2_500');
    expect(source).toContain('"X-IC-Recovery-Probe": "1"');
    expect(source).not.toContain('remoteBuildId');
    expect(source).not.toContain('isDocumentVisible');
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

  it('rate-limits offline reloads by time without storing sensitive navigation data', async () => {
    const source = fs.readFileSync(
      path.join(repositoryRoot, 'server/priv/static/pwa/offline.html'),
      'utf8'
    );
    const script = source.match(/<script>([\s\S]*?)<\/script>/u)?.[1];
    if (!script) throw new Error('Offline shell recovery script is missing.');

    let now = 1_000_000;
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
    const fetchMock = vi.fn(() => Promise.resolve(new Response(null, { status: 204 })));
    class FakeDate extends Date {
      static now() {
        return now;
      }
    }
    const context = {
      window: windowMock,
      document: documentMock,
      navigator: { language: 'en' },
      fetch: fetchMock,
      AbortController,
      URL,
      Date: FakeDate,
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
    expect(stored.get('intellectual-club:pwa:offline-reload')).toBe(String(now));
    expect(JSON.stringify(history.state)).not.toContain(targetUrl);
    expect([...stored.values()].join(' ')).not.toContain(targetUrl);

    now += 14_999;
    vm.runInNewContext(script, context);
    await flushProbe();
    expect(reload).toHaveBeenCalledTimes(1);

    now += 1;
    vm.runInNewContext(script, context);
    await flushProbe();

    expect(reload).toHaveBeenCalledTimes(2);
    expect(stored.get('intellectual-club:pwa:offline-reload')).toBe(String(now));
  });

  it('keeps an offline recovery probe scheduled across visibility changes', async () => {
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
      expect(fetchMock).toHaveBeenCalledTimes(2);
      expect(signals[1]?.aborted).toBe(false);
      expect(vi.getTimerCount()).toBeGreaterThan(0);

      setVisibility('visible');
      document.dispatchEvent(new Event('visibilitychange'));
      await Promise.resolve();
      await Promise.resolve();

      expect(signals[1]?.aborted).toBe(true);
      expect(fetchMock).toHaveBeenCalledTimes(3);
      expect(signals[2]?.aborted).toBe(false);

      setVisibility('hidden');
      document.dispatchEvent(new Event('visibilitychange'));
      await Promise.resolve();
      await Promise.resolve();

      expect(signals[2]?.aborted).toBe(true);
      expect(fetchMock).toHaveBeenCalledTimes(4);
      expect(signals[3]?.aborted).toBe(false);
      expect(vi.getTimerCount()).toBeGreaterThan(0);
    } finally {
      vi.unstubAllGlobals();
      vi.useRealTimers();
      if (originalVisibility) {
        Object.defineProperty(document, 'visibilityState', originalVisibility);
      }
    }
  });
});
