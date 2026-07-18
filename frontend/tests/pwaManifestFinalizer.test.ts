import { execFileSync, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const frontendRoot = path.resolve(import.meta.dirname, '..');
const finalizerPath = path.join(frontendRoot, 'scripts/finalize-pwa-manifest.mjs');
const appShellUrl = '/pwa/app-shell';
const supplementalAssets = [
  'pwa/offline.html',
  'favicon.png',
  'apple-touch-icon.png',
  'manifest.webmanifest',
  'images/pwa/icon-192.png',
  'images/pwa/icon-512.png',
  'images/pwa/icon-maskable-192.png',
  'images/pwa/icon-maskable-512.png',
];

const writeFixture = (staticDir: string, relativePath: string, contents = relativePath) => {
  const filePath = path.join(staticDir, relativePath);
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, contents);
};

const prepareFixture = (staticDir: string) => {
  writeFixture(staticDir, 'assets/js/spa.js', 'entry');
  writeFixture(staticDir, 'assets/css/app.css', 'shared styles');
  writeFixture(staticDir, 'assets/css/spa.css', 'styles');
  writeFixture(staticDir, 'assets/js/chunks/Route-abc123.js', 'route');
  writeFixture(staticDir, 'assets/code-version.json', JSON.stringify({ label: 'test' }));
  writeFixture(
    staticDir,
    'assets/pwa-bundle-descriptor.json',
    JSON.stringify({
      version: 1,
      entry: 'js/spa.js',
      css: ['css/spa.css'],
      precache: ['js/spa.js', 'js/chunks/Route-abc123.js', 'css/spa.css'],
    })
  );
  supplementalAssets.forEach((relativePath) => writeFixture(staticDir, relativePath));
};

const readGeneratedManifest = (staticDir: string) => {
  const source = fs.readFileSync(
    path.join(staticDir, 'assets/pwa-precache-manifest.js'),
    'utf8'
  );
  const match = source.match(/^self\.__PWA_PRECACHE_MANIFEST__ = Object\.freeze\(([\s\S]+)\);\n$/u);
  if (!match) throw new Error('Generated manifest has an unexpected format.');
  return JSON.parse(match[1]) as {
    buildId: string;
    mode: string;
    assets: string[];
  };
};

describe('PWA precache manifest finalizer', () => {
  let staticDir: string;

  beforeEach(() => {
    staticDir = fs.mkdtempSync(path.join(os.tmpdir(), 'intellectual-club-pwa-'));
    prepareFixture(staticDir);
  });

  afterEach(() => {
    fs.rmSync(staticDir, { recursive: true, force: true });
  });

  it('uses a stable code version when release copies change asset mtimes', () => {
    const expectedVersion = crypto
      .createHash('sha256')
      .update('test')
      .digest('hex')
      .slice(0, 16);

    execFileSync(process.execPath, [
      finalizerPath,
      '--mode',
      'dev',
      '--static-dir',
      staticDir,
    ]);
    const firstManifest = readGeneratedManifest(staticDir);

    fs.utimesSync(
      path.join(staticDir, 'assets/js/spa.js'),
      1_700_000_000,
      1_700_000_000
    );
    fs.utimesSync(
      path.join(staticDir, 'assets/css/spa.css'),
      1_800_000_000,
      1_800_000_000
    );

    execFileSync(process.execPath, [
      finalizerPath,
      '--mode',
      'dev',
      '--static-dir',
      staticDir,
    ]);

    const manifest = readGeneratedManifest(staticDir);
    expect(manifest.mode).toBe('dev');
    expect(manifest.buildId).toBe(`/assets/js/spa.js?v=${expectedVersion}`);
    expect(manifest.buildId).toBe(firstManifest.buildId);
    expect(manifest.assets).toContain(`/assets/css/app.css?v=${expectedVersion}`);
    expect(manifest.assets).toContain(`/assets/css/spa.css?v=${expectedVersion}`);
    expect(manifest.assets).toContain('/assets/js/chunks/Route-abc123.js');
    expect(manifest.assets).toContain(appShellUrl);
    expect(manifest.assets).toContain('/pwa/offline.html');
    expect(fs.existsSync(path.join(staticDir, appShellUrl.slice(1)))).toBe(false);
  });

  it('maps only the entry and CSS through the Phoenix digest manifest', () => {
    writeFixture(staticDir, 'assets/js/spa-digest.js', 'entry');
    writeFixture(staticDir, 'assets/css/app-digest.css', 'shared styles');
    writeFixture(staticDir, 'assets/css/spa-digest.css', 'styles');
    writeFixture(
      staticDir,
      'cache_manifest.json',
      JSON.stringify({
        latest: {
          'assets/js/spa.js': 'assets/js/spa-digest.js',
          'assets/css/app.css': 'assets/css/app-digest.css',
          'assets/css/spa.css': 'assets/css/spa-digest.css',
          'assets/js/chunks/Route-abc123.js':
            'assets/js/chunks/Route-abc123-phoenix-digest.js',
        },
      })
    );

    execFileSync(process.execPath, [
      finalizerPath,
      '--mode',
      'prod',
      '--static-dir',
      staticDir,
    ]);

    const manifest = readGeneratedManifest(staticDir);
    expect(manifest.mode).toBe('prod');
    expect(manifest.buildId).toBe('/assets/js/spa-digest.js?vsn=d');
    expect(manifest.assets).toContain('/assets/css/app-digest.css?vsn=d');
    expect(manifest.assets).toContain('/assets/css/spa-digest.css?vsn=d');
    expect(manifest.assets).toContain('/assets/js/chunks/Route-abc123.js');
    expect(manifest.assets).not.toContain(
      '/assets/js/chunks/Route-abc123-phoenix-digest.js?vsn=d'
    );
  });

  it.each([
    {
      name: 'path traversal',
      precache: ['js/spa.js', 'css/spa.css', '../secret.js'],
    },
    {
      name: 'duplicate paths',
      precache: ['js/spa.js', 'css/spa.css', 'css/spa.css'],
    },
    {
      name: 'generated metadata',
      precache: ['js/spa.js', 'css/spa.css', 'code-version.json'],
    },
    {
      name: 'optional Temml runtime',
      precache: ['js/spa.js', 'css/spa.css', 'temml.min.js'],
    },
    {
      name: 'missing required CSS',
      precache: ['js/spa.js', 'js/chunks/Route-abc123.js'],
    },
  ])('rejects invalid descriptor input: $name', ({ precache }) => {
    writeFixture(
      staticDir,
      'assets/pwa-bundle-descriptor.json',
      JSON.stringify({
        version: 1,
        entry: 'js/spa.js',
        css: ['css/spa.css'],
        precache,
      })
    );

    const result = spawnSync(
      process.execPath,
      [
        finalizerPath,
        '--mode',
        'dev',
        '--static-dir',
        staticDir,
      ],
      { encoding: 'utf8' }
    );

    expect(result.status).not.toBe(0);
    expect(
      fs.existsSync(path.join(staticDir, 'assets/pwa-precache-manifest.js'))
    ).toBe(false);
  });
});
