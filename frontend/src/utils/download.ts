type FileShareData = ShareData & {
  files: File[];
};

type FileShareNavigator = Navigator & {
  canShare?: (data?: FileShareData) => boolean;
  share?: (data?: FileShareData) => Promise<void>;
  standalone?: boolean;
};

function normalizeFilename(filename: string) {
  const trimmed = filename.trim();
  return trimmed === '' ? 'download' : trimmed;
}

function isIosDevice() {
  const userAgent = navigator.userAgent || '';
  const platform = navigator.platform || '';

  return (
    /iPad|iPhone|iPod/.test(userAgent) ||
    (platform === 'MacIntel' && navigator.maxTouchPoints > 1)
  );
}

function isStandalonePwa() {
  const nav = navigator as FileShareNavigator;
  return window.matchMedia('(display-mode: standalone)').matches || nav.standalone === true;
}

function shouldPreferFileShare(file: File) {
  if (!isIosDevice() || !isStandalonePwa()) return false;

  const nav = navigator as FileShareNavigator;
  if (typeof nav.share !== 'function' || typeof nav.canShare !== 'function') return false;

  try {
    return nav.canShare({ files: [file] });
  } catch {
    return false;
  }
}

export function shouldUseFileShareForDownloads() {
  const nav = navigator as FileShareNavigator;
  return (
    isIosDevice() &&
    isStandalonePwa() &&
    typeof nav.share === 'function' &&
    typeof nav.canShare === 'function'
  );
}

function saveBlobWithDownloadAttribute(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  link.style.display = 'none';
  document.body.appendChild(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 0);
}

function saveUrlWithDownloadAttribute(url: string, filename: string) {
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  link.style.display = 'none';
  document.body.appendChild(link);
  link.click();
  link.remove();
}

export async function saveBlobAsFile(blob: Blob, filename: string, mimeType?: string) {
  const name = normalizeFilename(filename);
  const type = mimeType || blob.type || 'application/octet-stream';
  const file = blob instanceof File && blob.name === name ? blob : new File([blob], name, { type });

  if (shouldPreferFileShare(file)) {
    await (navigator as FileShareNavigator).share?.({ files: [file], title: name });
    return;
  }

  saveBlobWithDownloadAttribute(blob, name);
}

export async function loadUrlAsFile(
  url: string,
  filename: string,
  mimeType?: string,
  signal?: AbortSignal
) {
  const name = normalizeFilename(filename);
  const response = await fetch(url, { credentials: 'same-origin', signal });
  if (!response.ok) throw new Error(`Failed to download attachment (${response.status})`);

  const blob = await response.blob();
  const type = mimeType || blob.type || 'application/octet-stream';
  return new File([blob], name, { type });
}

export async function saveUrlAsFile(url: string, filename: string, mimeType?: string) {
  const name = normalizeFilename(filename);

  if (!shouldUseFileShareForDownloads()) {
    saveUrlWithDownloadAttribute(url, name);
    return;
  }

  await saveBlobAsFile(await loadUrlAsFile(url, name, mimeType), name, mimeType);
}

export function isFileSaveAbort(error: unknown) {
  return error instanceof DOMException && error.name === 'AbortError';
}
