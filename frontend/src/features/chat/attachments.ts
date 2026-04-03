import type { Bot, ChatMessageContent, LlmConfiguration } from '@/types/api';

export type PendingChatFile = {
  id: string;
  file: File;
  name: string;
  size: number;
  mimeType: string;
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
const DEFAULT_MAX_FILE_SIZE_BYTES = 500 * 1024 * 1024;

export const formatFileBytes = (value: number) => {
  if (!Number.isFinite(value) || value < 0) return '0 B';
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
};

export const createPendingChatFiles = (files: File[]) =>
  files.map((file, index) => ({
    id: `${Date.now()}-${index}-${file.name}-${file.size}`,
    file,
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

export const pendingFileProgressPercent = (file: PendingChatFile) =>
  Math.max(0, Math.min(100, Math.round((Number.isFinite(file.progress) ? file.progress : 0) * 100)));

export const formatUploadSpeed = (bytesPerSecond: number) => {
  if (!Number.isFinite(bytesPerSecond) || bytesPerSecond <= 0) return '';
  return `${formatFileBytes(bytesPerSecond)}/s`;
};

export const formatUploadEta = (etaSeconds: number | null) => {
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
  configuration?: LlmConfiguration | null
): ChatUploadPolicy => {
  const maxFileSizeBytes =
    typeof bot?.max_file_size_bytes === 'number' && bot.max_file_size_bytes > 0
      ? bot.max_file_size_bytes
      : DEFAULT_MAX_FILE_SIZE_BYTES;

  const allowsAnyFiles = Boolean(bot?.supports_file_processing);
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

export const validateFilesForChatUpload = (files: File[], policy: ChatUploadPolicy) => {
  const accepted: File[] = [];
  const errors: string[] = [];

  for (const file of files) {
    if (!policy.allowsFiles) {
      errors.push('File uploads are disabled for the current bot and configuration.');
      continue;
    }

    if (policy.imagesOnly && !file.type.toLowerCase().startsWith('image/')) {
      errors.push(`Only image files are allowed. ${JSON.stringify(file.name)} was rejected.`);
      continue;
    }

    if (file.size > policy.maxFileSizeBytes) {
      errors.push(
        `File ${JSON.stringify(file.name)} exceeds the maximum size of ${formatFileBytes(
          policy.maxFileSizeBytes
        )}.`
      );
      continue;
    }

    accepted.push(file);
  }

  return { accepted, errors };
};

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

export const getAttachmentName = (content: ChatMessageContent) => content.media?.filename || 'Attachment';

export const getAttachmentMimeType = (content: ChatMessageContent) =>
  content.media?.mime_type || 'application/octet-stream';

export const getAttachmentSize = (content: ChatMessageContent) => content.media?.size_bytes || 0;

export const getAttachmentExtension = (name: string) => {
  const trimmed = name.trim();
  const parts = trimmed.split('.');
  return parts.length > 1 ? parts[parts.length - 1].toLowerCase() : '';
};

export const isMarkdownAttachment = (name: string, mimeType: string) => {
  const normalizedMimeType = mimeType.trim().toLowerCase();
  return (
    normalizedMimeType === 'text/markdown' ||
    normalizedMimeType === 'text/x-markdown' ||
    normalizedMimeType === 'application/markdown' ||
    MARKDOWN_EXTENSIONS.has(getAttachmentExtension(name))
  );
};

export const isTextAttachment = (name: string, mimeType: string) => {
  const normalizedMimeType = mimeType.trim().toLowerCase();

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

export const getAttachmentPreviewKind = (name: string, mimeType: string, isImage: boolean) => {
  if (isImage) return 'image' as const;
  if (isMarkdownAttachment(name, mimeType)) return 'markdown' as const;
  if (isTextAttachment(name, mimeType)) return 'text' as const;
  return 'binary' as const;
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
