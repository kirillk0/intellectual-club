import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const staticRoot = path.join(repositoryRoot, 'server/priv/static');
const requiredFiles = [
  'cache_manifest.json',
  'assets/code-version.json',
  'assets/pwa-bundle-descriptor.json',
  'assets/pwa-precache-manifest.js',
  'assets/js/spa.js',
  'assets/css/spa.css',
  'assets/css/app.css',
  'service-worker.js',
];

function fileHashes(root, prefix = '') {
  const entries = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const relative = prefix + entry.name;
    const absolute = path.join(root, entry.name);
    if (entry.isDirectory()) {
      entries.push(...Object.entries(fileHashes(absolute, `${relative}/`)));
    } else if (entry.isFile()) {
      entries.push([relative, crypto.createHash('sha256').update(fs.readFileSync(absolute)).digest('hex')]);
    } else {
      throw new Error(`Static assets must contain only regular files: ${relative}`);
    }
  }
  return Object.fromEntries(entries.sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0));
}

function validateCommit(commit) {
  if (!/^[a-f0-9]{40}$/.test(commit ?? '')) {
    throw new Error('A full Git commit SHA is required for prebuilt static assets.');
  }
}

function validateStatic(root, files) {
  for (const relative of requiredFiles) {
    if (!Object.hasOwn(files, relative)) throw new Error(`Missing production static asset: ${relative}`);
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'cache_manifest.json'), 'utf8'));
  for (const relative of ['assets/js/spa.js', 'assets/css/spa.css', 'assets/css/app.css']) {
    if (!Object.hasOwn(files, manifest.latest?.[relative] ?? '')) {
      throw new Error(`Missing digested static asset: ${relative}`);
    }
  }
}

function assertSeparateDirectories(first, second) {
  const a = path.resolve(first);
  const b = path.resolve(second);
  if (a === b || a.startsWith(b + path.sep) || b.startsWith(a + path.sep)) {
    throw new Error('The artifact and static directories must not overlap.');
  }
}

export function exportStatic(source, output, commit) {
  validateCommit(commit);
  assertSeparateDirectories(source, output);
  const files = fileHashes(source);
  validateStatic(source, files);
  if (fs.existsSync(output) && fs.readdirSync(output).length > 0) {
    throw new Error(`Static artifact output must be empty: ${output}`);
  }
  fs.mkdirSync(output, { recursive: true });
  fs.cpSync(source, path.join(output, 'static'), { recursive: true });
  fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify({ version: 1, commit, files }, null, 2) + '\n');
}

export function installStatic(input, destination, commit) {
  validateCommit(commit);
  assertSeparateDirectories(input, destination);
  const manifest = JSON.parse(fs.readFileSync(path.join(input, 'manifest.json'), 'utf8'));
  if (manifest.version !== 1 || manifest.commit !== commit) {
    throw new Error(`Static artifact does not match commit ${commit}`);
  }
  const source = path.join(input, 'static');
  const files = fileHashes(source);
  if (JSON.stringify(files) !== JSON.stringify(manifest.files)) {
    throw new Error('Static artifact file list or checksums do not match its manifest.');
  }
  validateStatic(source, files);
  fs.rmSync(destination, { recursive: true, force: true });
  fs.cpSync(source, destination, { recursive: true });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [command, directory, commit, ...extra] = process.argv.slice(2);
  try {
    if (!directory || extra.length || !['export', 'install'].includes(command)) {
      throw new Error('Usage: node bin/static-assets.mjs <export|install> <artifact-directory> <commit-sha>');
    }
    if (command === 'export') exportStatic(staticRoot, directory, commit);
    else installStatic(directory, staticRoot, commit);
    console.log(`Static assets ${command} completed for ${commit}`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
