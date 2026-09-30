import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { exportStatic, installStatic } from '../static-assets.mjs';

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const commit = 'a'.repeat(40);

function fixture(t) {
  const parent = path.join(repositoryRoot, 'assets');
  fs.mkdirSync(parent, { recursive: true });
  const root = fs.mkdtempSync(path.join(parent, 'static-assets-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const source = path.join(root, 'source');
  const artifact = path.join(root, 'artifact');
  const destination = path.join(root, 'destination');
  const latest = {};
  const contents = {
    'assets/code-version.json': '{"label":"build"}',
    'assets/pwa-bundle-descriptor.json': '{"version":1}',
    'assets/pwa-precache-manifest.js': 'self.__PWA_PRECACHE_MANIFEST__ = {};',
    'service-worker.js': '// worker',
    '.well-known/example': 'hidden asset',
    'assets/js/spa.js.gz': Buffer.from([0, 255, 1, 128]),
  };
  for (const file of ['assets/js/spa.js', 'assets/css/spa.css', 'assets/css/app.css']) {
    contents[file] = `compiled ${file}`;
    latest[file] = file.replace('.', '-digest.');
    contents[latest[file]] = contents[file];
  }
  contents['cache_manifest.json'] = JSON.stringify({ latest });
  for (const [file, value] of Object.entries(contents)) {
    fs.mkdirSync(path.dirname(path.join(source, file)), { recursive: true });
    fs.writeFileSync(path.join(source, file), value);
  }
  fs.mkdirSync(destination);
  fs.writeFileSync(path.join(destination, 'old.txt'), 'old build');
  return { source, artifact, destination, contents };
}

test('installs the complete production static tree byte for byte and removes stale files', (t) => {
  const { source, artifact, destination, contents } = fixture(t);
  exportStatic(source, artifact, commit);
  installStatic(artifact, destination, commit);
  installStatic(artifact, destination, commit);
  assert.equal(fs.existsSync(path.join(destination, 'old.txt')), false);
  for (const [file, value] of Object.entries(contents)) {
    assert.deepEqual(fs.readFileSync(path.join(destination, file)), Buffer.from(value));
  }
});

test('rejects a different commit before changing installed files', (t) => {
  const { source, artifact, destination } = fixture(t);
  exportStatic(source, artifact, commit);
  assert.throws(() => installStatic(artifact, destination, 'b'.repeat(40)), /does not match commit/);
  assert.equal(fs.readFileSync(path.join(destination, 'old.txt'), 'utf8'), 'old build');
});

for (const mutation of ['corrupt', 'missing', 'extra']) {
  test(`rejects ${mutation} artifact files before changing installed files`, (t) => {
    const { source, artifact, destination } = fixture(t);
    exportStatic(source, artifact, commit);
    const file = path.join(artifact, 'static/assets/js/spa.js');
    if (mutation === 'corrupt') fs.writeFileSync(file, 'corrupt');
    if (mutation === 'missing') fs.unlinkSync(file);
    if (mutation === 'extra') fs.writeFileSync(path.join(artifact, 'static/extra.txt'), 'extra');
    assert.throws(() => installStatic(artifact, destination, commit), /checksums do not match/);
    assert.equal(fs.existsSync(path.join(destination, 'old.txt')), true);
  });
}

test('refuses development output without the production digest manifest', (t) => {
  const { source, artifact } = fixture(t);
  fs.unlinkSync(path.join(source, 'cache_manifest.json'));
  assert.throws(() => exportStatic(source, artifact, commit), /Missing production static asset/);
});

test('refuses a digest manifest referring to a missing file', (t) => {
  const { source, artifact } = fixture(t);
  fs.unlinkSync(path.join(source, 'assets/js/spa-digest.js'));
  assert.throws(() => exportStatic(source, artifact, commit), /Missing digested static asset/);
});

test('refuses overlapping directories and invalid commit identifiers', (t) => {
  const { source, artifact } = fixture(t);
  assert.throws(() => exportStatic(source, source, commit), /must not overlap/);
  assert.throws(() => exportStatic(source, path.join(source, 'nested'), commit), /must not overlap/);
  assert.throws(() => exportStatic(source, artifact, 'main'), /full Git commit SHA/);
});

test('refuses symbolic links instead of copying files outside the artifact', (t) => {
  const { source, artifact, destination } = fixture(t);
  fs.symlinkSync(path.join(destination, 'old.txt'), path.join(source, 'linked.txt'));
  assert.throws(() => exportStatic(source, artifact, commit), /only regular files/);
});
