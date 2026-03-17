import type { ImageAsset } from '@/types/api';

export function parseImageAsset(value: unknown): ImageAsset | null {
  if (!value || typeof value !== 'object') return null;

  const source = value as Record<string, unknown>;
  const url = typeof source.url === 'string' ? source.url : '';
  const filename = typeof source.filename === 'string' ? source.filename : '';
  const mime_type = typeof source.mime_type === 'string' ? source.mime_type : '';
  const sha256 = typeof source.sha256 === 'string' ? source.sha256 : '';

  if (!url || !mime_type || !sha256) return null;

  return {
    url,
    filename,
    mime_type,
    size_bytes: typeof source.size_bytes === 'number' ? source.size_bytes : Number(source.size_bytes || 0),
    sha256,
  };
}

export function imageUrlWithVersion(image: Pick<ImageAsset, 'url' | 'sha256'> | null | undefined) {
  if (!image?.url) return '';
  const separator = image.url.includes('?') ? '&' : '?';
  return `${image.url}${separator}v=${encodeURIComponent(image.sha256 || '')}`;
}

export function imageFallbackText(label: string | null | undefined, fallback = '?') {
  const trimmed = String(label || '').trim();
  if (!trimmed) return fallback;
  return trimmed.charAt(0).toUpperCase();
}
