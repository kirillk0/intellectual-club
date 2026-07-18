import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const frontendRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const defaultStaticDir = path.resolve(frontendRoot, '../server/priv/static');
const descriptorRelativePath = 'assets/pwa-bundle-descriptor.json';
const codeVersionRelativePath = 'assets/code-version.json';
const cacheManifestRelativePath = 'cache_manifest.json';
const outputRelativePath = 'assets/pwa-precache-manifest.js';
const appShellUrl = '/pwa/app-shell';
const sharedShellAssets = ['css/app.css'];
const supplementalAssets = [
  appShellUrl,
  '/pwa/offline.html',
  '/favicon.png',
  '/apple-touch-icon.png',
  '/manifest.webmanifest',
  '/images/pwa/icon-192.png',
  '/images/pwa/icon-512.png',
  '/images/pwa/icon-maskable-192.png',
  '/images/pwa/icon-maskable-512.png',
];

const readJson = (filePath) => JSON.parse(fs.readFileSync(filePath, 'utf8'));

const forbiddenDescriptorPath = (relativePath) =>
  relativePath === 'code-version.json' ||
  relativePath === 'pwa-bundle-descriptor.json' ||
  relativePath === 'pwa-precache-manifest.js' ||
  relativePath === 'temml.min.js' ||
  relativePath.endsWith('.map') ||
  relativePath.endsWith('.gz');

const validateRelativeAssetPath = (relativePath) => {
  if (
    typeof relativePath !== 'string' ||
    relativePath.length === 0 ||
    relativePath.startsWith('/') ||
    relativePath.includes('\\') ||
    relativePath.includes('?') ||
    relativePath.includes('#') ||
    relativePath.includes(':') ||
    path.posix.normalize(relativePath) !== relativePath ||
    relativePath.startsWith('../') ||
    forbiddenDescriptorPath(relativePath)
  ) {
    throw new Error(`Invalid PWA descriptor asset path: ${String(relativePath)}`);
  }
};

const validateDescriptor = (descriptor) => {
  if (
    descriptor?.version !== 1 ||
    typeof descriptor.entry !== 'string' ||
    !Array.isArray(descriptor.css) ||
    !Array.isArray(descriptor.precache) ||
    descriptor.precache.length === 0
  ) {
    throw new Error('Vite PWA bundle descriptor is invalid.');
  }

  validateRelativeAssetPath(descriptor.entry);
  descriptor.css.forEach(validateRelativeAssetPath);
  descriptor.precache.forEach(validateRelativeAssetPath);

  if (!descriptor.entry.endsWith('.js')) {
    throw new Error('Vite PWA entry must be a JavaScript asset.');
  }

  if (descriptor.css.some((relativePath) => !relativePath.endsWith('.css'))) {
    throw new Error('Vite PWA CSS entries must be stylesheet assets.');
  }

  const uniquePrecache = new Set(descriptor.precache);
  if (uniquePrecache.size !== descriptor.precache.length) {
    throw new Error('Vite PWA bundle descriptor contains duplicate assets.');
  }

  const requiredAssets = [descriptor.entry, ...descriptor.css];
  const missingRequired = requiredAssets.filter((asset) => !uniquePrecache.has(asset));
  if (missingRequired.length > 0) {
    throw new Error(
      `Vite PWA descriptor does not precache required assets: ${missingRequired.join(', ')}`
    );
  }
};

const canonicalAssetUrl = (relativePath) => `/assets/${relativePath.replace(/^\/+/u, '')}`;

const developmentAssetVersion = (codeVersion) => {
  const label = codeVersion?.label;

  if (typeof label !== 'string' || label.trim().length === 0) {
    throw new Error('Code version label is invalid.');
  }

  return crypto.createHash('sha256').update(label.trim()).digest('hex').slice(0, 16);
};

const developmentEntryUrl = (relativePath, version) => {
  return `${canonicalAssetUrl(relativePath)}?v=${version}`;
};

const digestEntryUrl = (relativePath, cacheManifest) => {
  const manifestKey = `assets/${relativePath.replace(/^\/+/u, '')}`;
  const digestedPath = cacheManifest?.latest?.[manifestKey];

  if (typeof digestedPath !== 'string' || digestedPath.length === 0) {
    throw new Error(`Phoenix digest manifest does not contain ${manifestKey}.`);
  }

  return `/${digestedPath}?vsn=d`;
};

const resolvePrecacheUrls = ({
  descriptor,
  mode,
  cacheManifest,
  developmentVersion,
}) => {
  const entryPaths = new Set([descriptor.entry, ...(descriptor.css || [])]);

  return descriptor.precache.map((relativePath) => {
    if (mode === 'prod' && entryPaths.has(relativePath)) {
      return digestEntryUrl(relativePath, cacheManifest);
    }

    if (mode === 'dev' && entryPaths.has(relativePath)) {
      return developmentEntryUrl(relativePath, developmentVersion);
    }

    return canonicalAssetUrl(relativePath);
  });
};

const resolveSharedShellUrls = ({
  mode,
  cacheManifest,
  developmentVersion,
}) =>
  sharedShellAssets.map((relativePath) =>
    mode === 'prod'
      ? digestEntryUrl(relativePath, cacheManifest)
      : developmentEntryUrl(relativePath, developmentVersion)
  );

const filePathForUrl = (staticDir, url) => {
  const parsed = new URL(url, 'https://pwa.local');
  return path.join(staticDir, decodeURIComponent(parsed.pathname).replace(/^\/+/u, ''));
};

const assertAssetsExist = (staticDir, urls) => {
  const missing = urls
    .filter((url) => url !== appShellUrl)
    .filter((url) => !fs.existsSync(filePathForUrl(staticDir, url)));

  if (missing.length > 0) {
    throw new Error(`PWA precache assets are missing:\n${missing.join('\n')}`);
  }
};

const revisionFor = (staticDir, urls) => {
  const hash = crypto.createHash('sha256');

  for (const url of urls) {
    if (url === appShellUrl) continue;
    hash.update(url);
    hash.update(fs.readFileSync(filePathForUrl(staticDir, url)));
  }

  return hash.digest('hex').slice(0, 24);
};

const writeAtomically = (filePath, contents) => {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const temporaryPath = `${filePath}.${process.pid}.tmp`;
  fs.writeFileSync(temporaryPath, contents);
  fs.renameSync(temporaryPath, filePath);
};

export const finalizePwaManifest = ({
  mode,
  staticDir = defaultStaticDir,
} = {}) => {
  if (mode !== 'dev' && mode !== 'prod') {
    throw new Error('PWA manifest mode must be either "dev" or "prod".');
  }

  const descriptor = readJson(path.join(staticDir, descriptorRelativePath));
  const codeVersion = readJson(path.join(staticDir, codeVersionRelativePath));
  const cacheManifest =
    mode === 'prod'
      ? readJson(path.join(staticDir, cacheManifestRelativePath))
      : null;
  const developmentVersion =
    mode === 'dev' ? developmentAssetVersion(codeVersion) : null;

  validateDescriptor(descriptor);

  const assets = [
    ...resolvePrecacheUrls({
      descriptor,
      mode,
      cacheManifest,
      developmentVersion,
    }),
    ...resolveSharedShellUrls({
      mode,
      cacheManifest,
      developmentVersion,
    }),
    ...supplementalAssets,
  ].filter((url, index, urls) => urls.indexOf(url) === index);

  assertAssetsExist(staticDir, assets);

  const output = {
    version: 1,
    buildId: assets[0],
    revision: revisionFor(staticDir, assets),
    mode,
    offlineUrl: '/pwa/offline.html',
    assets,
  };
  const source =
    `self.__PWA_PRECACHE_MANIFEST__ = Object.freeze(${JSON.stringify(output, null, 2)});\n`;
  const outputPath = path.join(staticDir, outputRelativePath);

  writeAtomically(outputPath, source);

  return { output, outputPath };
};

const parseCliArguments = (argumentsList) => {
  const options = {};

  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    const value = argumentsList[index + 1];

    if (argument === '--mode' && value) {
      options.mode = value;
      index += 1;
      continue;
    }

    if (argument === '--static-dir' && value) {
      options.staticDir = path.resolve(value);
      index += 1;
      continue;
    }

    throw new Error(`Unknown or incomplete argument: ${argument}`);
  }

  return options;
};

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : '';
const currentPath = fileURLToPath(import.meta.url);

if (invokedPath === currentPath) {
  const result = finalizePwaManifest(parseCliArguments(process.argv.slice(2)));
  process.stdout.write(
    `Generated ${path.relative(process.cwd(), result.outputPath)} with ${result.output.assets.length} assets.\n`
  );
}
