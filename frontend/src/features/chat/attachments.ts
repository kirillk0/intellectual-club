import type { ImageConversionResult, ImageUploadPlan } from '@/features/chat/imageNormalization';
import { translate } from '@/i18n';
import type { Bot, ChatMessageContent, LlmConfiguration } from '@/types/api';

export type ChatAttachmentOpenPayload = {
  messageId: number;
  contents?: ChatMessageContent[] | null;
} & ({ content: ChatMessageContent } | { fileId: string });

// Browser-side normalization of a pending image (see imageNormalization.ts).
export type PendingImageState = {
  // 'inspecting' until the header is read, 'processing' while a compressed copy is
  // being prepared, 'ready' afterwards.
  phase: 'inspecting' | 'processing' | 'ready';
  // Upload the selected file untouched instead of the compressed copy.
  keepOriginal: boolean;
  // Whether the untouched file reaches the model as an image; null while unknown.
  originalEmbeddable: boolean | null;
  original: { width: number | null; height: number | null; size: number };
  compressed: { file: File; width: number; height: number } | null;
  // The browser could not prepare a compressed copy, so the original is uploaded.
  failed: boolean;
  // Largest upload the policy accepted when the file was added; null without a limit.
  // An original above it cannot be chosen, only its compressed copy.
  sizeLimitBytes: number | null;
};

export type PendingChatFile = {
  id: string;
  // The variant that is uploaded; `name`, `size` and `mimeType` describe it.
  file: File;
  name: string;
  size: number;
  mimeType: string;
  // The file as selected by the user; defaults to `file`.
  sourceFile?: File;
  // Absent for files that are not images.
  image?: PendingImageState | null;
  // Bumped whenever the uploaded variant changes, so in-flight uploads notice they are stale.
  variantRevision?: number;
  uploadId: string | null;
  uploadStatus: 'idle' | 'uploading' | 'uploaded' | 'error';
  uploadedBytes: number;
  progress: number;
  speedBps: number;
  etaSeconds: number | null;
  abortHandle: (() => void) | null;
  error: string;
};

export type ExistingChatAttachment = {
  id: number;
  messageId: number;
  queuedMessageId?: number;
  name: string;
  size: number;
  mimeType: string;
  isImage: boolean;
  content: ChatMessageContent;
};

export type ChatUploadPolicy = {
  allowsFiles: boolean;
  imagesOnly: boolean;
  maxFileSizeBytes: number;
  accept: string;
};

const MARKDOWN_EXTENSIONS = new Set(['md', 'markdown', 'mdown', 'mkd']);
const HTML_EXTENSIONS = new Set(['html', 'htm', 'xhtml']);
const DEFAULT_MAX_FILE_SIZE_BYTES = 500 * 1024 * 1024;

export type AttachmentPreviewKind = 'image' | 'video' | 'audio' | 'pdf' | 'html' | 'markdown' | 'text' | 'binary';

export const formatFileBytes = (value: number) => {
  if (!Number.isFinite(value) || value < 0) return '0 B';
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
};

export const createPendingChatFiles = (files: File[]): PendingChatFile[] =>
  files.map((file, index) => ({
    id: `${Date.now()}-${index}-${file.name}-${file.size}`,
    file,
    sourceFile: file,
    name: file.name,
    size: file.size,
    mimeType: file.type || 'application/octet-stream',
    uploadId: null,
    uploadStatus: 'idle' as const,
    uploadedBytes: 0,
    progress: 0,
    speedBps: 0,
    etaSeconds: null,
    abortHandle: null,
    error: '',
  }));

export const isImageMimeType = (mimeType: string) => mimeType.trim().toLowerCase().startsWith('image/');

export const initialPendingImageState = (file: File, sizeLimitBytes: number | null = null): PendingImageState => ({
  phase: 'inspecting',
  keepOriginal: false,
  originalEmbeddable: null,
  original: { width: null, height: null, size: file.size },
  compressed: null,
  failed: false,
  sizeLimitBytes,
});

export const pendingImageStateAfterInspection = (
  image: PendingImageState,
  plan: ImageUploadPlan
): PendingImageState => ({
  ...image,
  phase: plan.action === 'keep' ? 'ready' : 'processing',
  originalEmbeddable: plan.action === 'keep',
  original: { ...image.original, width: plan.header.width, height: plan.header.height },
});

export const pendingImageStateAfterConversion = (
  image: PendingImageState,
  result: ImageConversionResult
): PendingImageState => {
  if (result.kind === 'converted') {
    return {
      ...image,
      phase: 'ready',
      original: { ...image.original, width: result.sourceWidth, height: result.sourceHeight },
      compressed: { file: result.file, width: result.width, height: result.height },
      failed: false,
    };
  }

  if (result.kind === 'unchanged') {
    return {
      ...image,
      phase: 'ready',
      originalEmbeddable: true,
      original: { ...image.original, width: result.width, height: result.height },
      compressed: null,
      failed: false,
    };
  }

  return { ...image, phase: 'ready', compressed: null, failed: true };
};

const pendingSourceFile = (item: PendingChatFile) => item.sourceFile ?? item.file;

/** The file to upload, or null while its compressed copy is still being prepared. */
export const pendingFileUploadTarget = (item: PendingChatFile): File | null => {
  const image = item.image;
  if (!image || image.keepOriginal) return pendingSourceFile(item);
  if (image.phase !== 'ready') return null;
  return image.compressed?.file ?? pendingSourceFile(item);
};

const originalOverSizeLimit = (image: PendingImageState) =>
  image.sizeLimitBytes !== null && image.original.size > image.sizeLimitBytes;

// Without a compressed copy the original is uploaded either way; an original over the
// size limit would be rejected by the server.
export const canTogglePendingImageOriginal = (image: PendingImageState) =>
  !originalOverSizeLimit(image) && (image.phase !== 'ready' || image.compressed !== null);

const IDLE_UPLOAD_STATE = {
  uploadId: null,
  uploadStatus: 'idle',
  uploadedBytes: 0,
  progress: 0,
  speedBps: 0,
  etaSeconds: null,
  abortHandle: null,
  error: '',
} satisfies Partial<PendingChatFile>;

/**
 * Patch that applies a new image state. When the variant to upload changes, the upload
 * state is reset and `variantChanged` is set: the caller then aborts the transfer and
 * the upload session of the previous variant.
 */
export const pendingImageStatePatch = (item: PendingChatFile, image: PendingImageState | null) => {
  const previousTarget = pendingFileUploadTarget(item);
  const nextTarget = pendingFileUploadTarget({ ...item, image });
  const shown = nextTarget ?? pendingSourceFile(item);
  const variantChanged = previousTarget !== nextTarget;
  const patch: Partial<PendingChatFile> = {
    image,
    file: shown,
    name: shown.name,
    size: shown.size,
    mimeType: shown.type || 'application/octet-stream',
    ...(variantChanged ? { ...IDLE_UPLOAD_STATE, variantRevision: (item.variantRevision ?? 0) + 1 } : {}),
  };

  return { patch, variantChanged };
};

const describeImageSize = (width: number | null, height: number | null, bytes: number) =>
  [width && height ? `${width}×${height}` : '', formatFileBytes(bytes)].filter(Boolean).join(', ');

export type PendingImageSummary = {
  originalChecked: boolean;
  toggleDisabled: boolean;
  toggleTitle: string;
  note: string;
  warning: boolean;
};

export const describePendingImage = (image: PendingImageState): PendingImageSummary => {
  if (image.phase === 'ready' && !image.compressed) {
    const note = image.failed
      ? translate("The browser couldn't process this image, so the model gets it only as a file.")
      : translate('Fits the model limits');
    return {
      originalChecked: true,
      toggleDisabled: true,
      toggleTitle: image.failed ? note : translate('The image fits the model limits and is uploaded unchanged.'),
      note,
      warning: image.failed,
    };
  }

  const overSizeLimit = originalOverSizeLimit(image);
  const toggleTitle = overSizeLimit
    ? translate('The original exceeds the maximum file size of {size}', {
        size: formatFileBytes(image.sizeLimitBytes ?? 0),
      })
    : translate('Upload the original file without compression');
  if (image.keepOriginal) {
    const linked = image.originalEmbeddable === false;
    return {
      originalChecked: true,
      toggleDisabled: false,
      toggleTitle,
      note: linked ? translate('The model gets a link to the file instead of the image') : '',
      warning: linked,
    };
  }

  return {
    originalChecked: false,
    toggleDisabled: overSizeLimit,
    toggleTitle,
    note: image.compressed
      ? `${describeImageSize(image.original.width, image.original.height, image.original.size)} → ${describeImageSize(
          image.compressed.width,
          image.compressed.height,
          image.compressed.file.size
        )}`
      : '',
    warning: false,
  };
};

export const pendingFileProgressPercent = (file: PendingChatFile) =>
  Math.max(0, Math.min(100, Math.round((Number.isFinite(file.progress) ? file.progress : 0) * 100)));

const formatUploadSpeed = (bytesPerSecond: number) => {
  if (!Number.isFinite(bytesPerSecond) || bytesPerSecond <= 0) return '';
  return `${formatFileBytes(bytesPerSecond)}/s`;
};

const formatUploadEta = (etaSeconds: number | null) => {
  if (etaSeconds == null || !Number.isFinite(etaSeconds) || etaSeconds < 0) return '';
  if (etaSeconds < 60) return `${Math.round(etaSeconds)}s left`;

  const minutes = Math.floor(etaSeconds / 60);
  const seconds = Math.round(etaSeconds % 60);
  return `${minutes}m ${seconds}s left`;
};

export const describePendingFileUploadStatus = (file: PendingChatFile) => {
  if (file.uploadStatus === 'uploaded') {
    return 'Uploaded';
  }

  if (file.uploadStatus === 'error') {
    return file.error.trim() || 'Upload failed. Retry to continue.';
  }

  if (file.uploadStatus === 'uploading') {
    const details = [
      `${pendingFileProgressPercent(file)}%`,
      `${formatFileBytes(file.uploadedBytes)} / ${formatFileBytes(file.size)}`,
      formatUploadSpeed(file.speedBps),
      formatUploadEta(file.etaSeconds),
    ].filter(Boolean);

    return `Uploading… ${details.join(' • ')}`;
  }

  if (file.image?.phase === 'processing' && !file.image.keepOriginal) {
    return translate('Processing image…');
  }

  return `${formatFileBytes(file.size)} ready to upload`;
};

export const overallPendingUploadProgress = (files: PendingChatFile[]) => {
  const relevantFiles = files.filter(
    (file) =>
      file.uploadStatus === 'uploading' ||
      file.uploadStatus === 'uploaded' ||
      file.uploadedBytes > 0
  );

  if (relevantFiles.length === 0) {
    return { active: false, progress: 0 };
  }

  const totalBytes = relevantFiles.reduce((sum, file) => sum + Math.max(0, file.size), 0);
  const uploadedBytes = relevantFiles.reduce(
    (sum, file) => sum + Math.min(Math.max(0, file.uploadedBytes), Math.max(0, file.size)),
    0
  );

  if (totalBytes <= 0) {
    return { active: false, progress: 0 };
  }

  return {
    active: uploadedBytes < totalBytes,
    progress: Math.max(0, Math.min(1, uploadedBytes / totalBytes)),
  };
};

export const resolveChatUploadPolicy = (
  bot?: Bot | null,
  configuration?: LlmConfiguration | null,
  artifactToolsAvailable = false
): ChatUploadPolicy => {
  const maxFileSizeBytes =
    typeof bot?.max_file_size_bytes === 'number' && bot.max_file_size_bytes > 0
      ? bot.max_file_size_bytes
      : DEFAULT_MAX_FILE_SIZE_BYTES;

  const allowsAnyFiles = Boolean(artifactToolsAvailable);
  const allowsImages = allowsAnyFiles || Boolean(configuration?.supports_image_input);

  return {
    allowsFiles: allowsAnyFiles || allowsImages,
    imagesOnly: !allowsAnyFiles && allowsImages,
    maxFileSizeBytes,
    accept: allowsAnyFiles ? '' : allowsImages ? 'image/*' : '',
  };
};

export const describeChatUploadPolicy = (policy: ChatUploadPolicy) => {
  if (!policy.allowsFiles) {
    return 'File uploads are disabled for the current bot and configuration.';
  }

  if (policy.imagesOnly) {
    return `Only image files up to ${formatFileBytes(policy.maxFileSizeBytes)} are allowed.`;
  }

  return `Files up to ${formatFileBytes(policy.maxFileSizeBytes)} are allowed.`;
};

const fileSizeLimitError = (name: string, maxFileSizeBytes: number) =>
  `File ${JSON.stringify(name)} exceeds the maximum size of ${formatFileBytes(maxFileSizeBytes)}.`;

// Policy checks other than the size limit.
const fileKindPolicyError = (file: File, policy: ChatUploadPolicy) => {
  if (!policy.allowsFiles) return 'File uploads are disabled for the current bot and configuration.';
  if (policy.imagesOnly && !file.type.toLowerCase().startsWith('image/')) {
    return `Only image files are allowed. ${JSON.stringify(file.name)} was rejected.`;
  }
  return '';
};

export type ChatUploadValidationOptions = {
  // Images may be uploaded as a compressed copy: their size is left to pendingFileSizeError,
  // which checks the variant that is actually uploaded.
  deferImageSizeCheck?: boolean;
};

export const validateFilesForChatUpload = (
  files: File[],
  policy: ChatUploadPolicy,
  options: ChatUploadValidationOptions = {}
) => {
  const accepted: File[] = [];
  const errors: string[] = [];

  for (const file of files) {
    const checkSize = !(options.deferImageSizeCheck && isImageMimeType(file.type));
    const error =
      fileKindPolicyError(file, policy) ||
      (checkSize && file.size > policy.maxFileSizeBytes ? fileSizeLimitError(file.name, policy.maxFileSizeBytes) : '');

    if (error) errors.push(error);
    else accepted.push(file);
  }

  return { accepted, errors };
};

/**
 * The size limit error of the variant an attachment uploads, named after the selected
 * file; '' within the limit and while the variant is not known yet.
 */
export const pendingFileSizeError = (item: PendingChatFile, maxFileSizeBytes: number) => {
  const target = pendingFileUploadTarget(item);
  return target && target.size > maxFileSizeBytes
    ? fileSizeLimitError(pendingSourceFile(item).name, maxFileSizeBytes)
    : '';
};

/** Upload policy errors of added attachments, each checked by the variant it uploads. */
export const validatePendingFilesForChatUpload = (items: PendingChatFile[], policy: ChatUploadPolicy) =>
  items
    .map(
      (item) =>
        fileKindPolicyError(pendingSourceFile(item), policy) || pendingFileSizeError(item, policy.maxFileSizeBytes)
    )
    .filter((error) => error !== '');

export const extractClipboardImageFiles = (event: ClipboardEvent) => {
  const clipboardData = event.clipboardData;
  if (!clipboardData) return [];

  return Array.from(clipboardData.items || [])
    .filter((item) => item.kind === 'file' && item.type.toLowerCase().startsWith('image/'))
    .map((item) => item.getAsFile())
    .filter((file): file is File => file instanceof File);
};

export const clipboardHasStringContent = (event: ClipboardEvent) => {
  const clipboardData = event.clipboardData;
  if (!clipboardData) return false;

  if ((clipboardData.getData('text/plain') || '').length > 0) return true;
  if ((clipboardData.getData('text/html') || '').length > 0) return true;

  return Array.from(clipboardData.items || []).some((item) => item.kind === 'string');
};

export const buildMessageContentFileUrl = (messageId: number, contentId: number) =>
  `/api/bff/chat-messages/${messageId}/contents/${contentId}/file`;

export const buildQueuedMessageContentFileUrl = (queuedMessageId: number, contentId: number) =>
  `/api/bff/chat-queued-messages/${queuedMessageId}/contents/${contentId}/file`;

export const getAttachmentName = (content: ChatMessageContent) => content.media?.filename || 'Attachment';

export const getAttachmentMimeType = (content: ChatMessageContent) =>
  content.media?.mime_type || 'application/octet-stream';

export const getAttachmentSize = (content: ChatMessageContent) => content.media?.size_bytes || 0;

const getAttachmentExtension = (name: string) => {
  const trimmed = name.trim();
  const parts = trimmed.split('.');
  return parts.length > 1 ? parts[parts.length - 1].toLowerCase() : '';
};

const normalizeAttachmentMimeType = (mimeType: string) =>
  mimeType.split(';', 1)[0]?.trim().toLowerCase() || '';

const isMarkdownAttachment = (name: string, mimeType: string) => {
  const normalizedMimeType = normalizeAttachmentMimeType(mimeType);
  return (
    normalizedMimeType === 'text/markdown' ||
    normalizedMimeType === 'text/x-markdown' ||
    normalizedMimeType === 'application/markdown' ||
    MARKDOWN_EXTENSIONS.has(getAttachmentExtension(name))
  );
};

const isHtmlAttachment = (name: string, mimeType: string) => {
  const normalizedMimeType = normalizeAttachmentMimeType(mimeType);
  return (
    normalizedMimeType === 'text/html' ||
    normalizedMimeType === 'application/xhtml+xml' ||
    HTML_EXTENSIONS.has(getAttachmentExtension(name))
  );
};

const isTextAttachment = (name: string, mimeType: string) => {
  const normalizedMimeType = normalizeAttachmentMimeType(mimeType);

  if (isMarkdownAttachment(name, mimeType)) return true;
  if (normalizedMimeType.startsWith('text/')) return true;

  return new Set([
    'application/json',
    'application/xml',
    'application/javascript',
    'application/x-javascript',
    'application/typescript',
    'application/x-sh',
    'application/yaml',
    'application/x-yaml',
  ]).has(normalizedMimeType);
};

export const getAttachmentPreviewKind = (
  name: string,
  mimeType: string,
  isImage: boolean
): AttachmentPreviewKind => {
  if (isImage) return 'image';
  const normalizedMimeType = normalizeAttachmentMimeType(mimeType);
  if (normalizedMimeType.startsWith('video/')) return 'video';
  if (normalizedMimeType.startsWith('audio/')) return 'audio';
  if (normalizedMimeType === 'application/pdf') return 'pdf';
  if (isHtmlAttachment(name, mimeType)) return 'html';
  if (isMarkdownAttachment(name, mimeType)) return 'markdown';
  if (isTextAttachment(name, mimeType)) return 'text';
  return 'binary';
};

export const mapContentToExistingAttachment = (
  content: ChatMessageContent,
  messageId: number
): ExistingChatAttachment | null => {
  if (content.kind !== 'media' || !content.media) return null;

  return {
    id: content.id,
    messageId,
    name: getAttachmentName(content),
    size: getAttachmentSize(content),
    mimeType: getAttachmentMimeType(content),
    isImage: Boolean(content.media?.is_image),
    content,
  };
};

/** Return an icon name for a file based on its mime type and name. */
export const fileIconByMime = (mime: string, filename: string): string => {
  const m = (mime || '').toLowerCase();
  const n = (filename || '').toLowerCase();
  if (m.startsWith('image/')) return 'file-image';
  if (m.startsWith('audio/')) return 'file-audio';
  if (m.startsWith('video/')) return 'file-video';
  if (m === 'application/pdf') return 'file-pdf';
  if (m.includes('spreadsheet') || m.includes('excel') || m === 'text/csv') return 'file-spreadsheet';
  if (m.includes('presentation') || m.includes('powerpoint')) return 'file-presentation';
  if (m.includes('word') || m.includes('document')) return 'file-doc';
  if (n.endsWith('.md') || m === 'text/markdown' || m === 'text/x-markdown') return 'file-markdown';
  if (m.startsWith('text/')) return 'file-text';
  if (m.includes('json') || n.endsWith('.json')) return 'file-code';
  if (m.includes('zip') || m.includes('tar') || m.includes('compress')) return 'file-archive';
  return 'file-generic';
};
