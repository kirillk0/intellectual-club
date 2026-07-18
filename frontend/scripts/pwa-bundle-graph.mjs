const normalizedModuleId = (chunk) => (chunk.facadeModuleId || '').replaceAll('\\', '/');

const isRouteView = (chunk) =>
  chunk.isDynamicEntry === true &&
  /\/src\/views\/.+\.vue$/u.test(normalizedModuleId(chunk));

const isOptionalRuntimeAsset = (fileName) =>
  fileName === 'temml.min.js' || fileName.endsWith('/temml.min.js');

export const CRITICAL_ENTRY_MAX_BYTES = 750 * 1024;

const entryChunk = (bundle) =>
  Object.values(bundle)
    .filter((output) => output.type === 'chunk')
    .find((chunk) => chunk.isEntry);

export const validateCriticalEntry = (bundle) => {
  const entry = entryChunk(bundle);
  if (!entry) throw new Error('Unable to find the SPA entry chunk.');

  const chunks = new Map(
    Object.values(bundle)
      .filter((output) => output.type === 'chunk')
      .map((chunk) => [chunk.fileName, chunk])
  );
  const criticalFiles = new Set();
  const visit = (fileName) => {
    if (criticalFiles.has(fileName)) return;
    const chunk = chunks.get(fileName);
    if (!chunk) return;

    criticalFiles.add(fileName);
    (chunk.imports || []).forEach(visit);
  };

  visit(entry.fileName);

  const criticalChunks = [...criticalFiles].map((fileName) => chunks.get(fileName));
  const size = criticalChunks.reduce(
    (total, chunk) => total + Buffer.byteLength(chunk.code, 'utf8'),
    0
  );
  if (size > CRITICAL_ENTRY_MAX_BYTES) {
    throw new Error(
      `SPA critical static closure is ${size} bytes; the limit is ${CRITICAL_ENTRY_MAX_BYTES} bytes.`
    );
  }

  if (
    criticalChunks.some((chunk) =>
      /data:image\/(?:avif|bmp|gif|jpeg|jpg|png|webp);base64,/iu.test(chunk.code)
    )
  ) {
    throw new Error('SPA critical static closure contains an inline base64 raster image.');
  }

  return { fileNames: [...criticalFiles], size };
};

export const buildPwaBundleDescriptor = (bundle) => {
  const chunks = new Map(
    Object.values(bundle)
      .filter((output) => output.type === 'chunk')
      .map((chunk) => [chunk.fileName, chunk])
  );
  const entry = entryChunk(bundle);

  if (!entry) {
    throw new Error('Unable to find the SPA entry chunk for the PWA descriptor.');
  }

  const includedChunks = new Set();
  const visitStaticClosure = (fileName) => {
    if (includedChunks.has(fileName)) return;

    const chunk = chunks.get(fileName);
    if (!chunk) return;

    includedChunks.add(fileName);
    chunk.imports.forEach(visitStaticClosure);
  };

  visitStaticClosure(entry.fileName);

  const routeEntries = [...includedChunks]
    .flatMap((fileName) => chunks.get(fileName)?.dynamicImports || [])
    .filter((fileName, index, values) => values.indexOf(fileName) === index)
    .filter((fileName) => {
      const chunk = chunks.get(fileName);
      return chunk ? isRouteView(chunk) : false;
    });

  routeEntries.forEach(visitStaticClosure);

  const referencedAssets = new Set();
  for (const fileName of includedChunks) {
    const metadata = chunks.get(fileName)?.viteMetadata;
    metadata?.importedAssets?.forEach((asset) => {
      if (!isOptionalRuntimeAsset(asset)) referencedAssets.add(asset);
    });
  }

  const css = ['css/spa.css'];
  const precache = [
    entry.fileName,
    ...[...includedChunks].filter((fileName) => fileName !== entry.fileName).sort(),
    ...css,
    ...[...referencedAssets].sort(),
  ].filter((fileName, index, values) => values.indexOf(fileName) === index);

  return {
    version: 1,
    entry: entry.fileName,
    css,
    precache,
  };
};
