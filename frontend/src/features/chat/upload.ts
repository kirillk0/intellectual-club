import { api, getCsrfToken, HttpError, isHttpError } from '@/api/client';

type ChatUploadStatus = 'uploading' | 'uploaded' | 'aborted' | 'expired' | string;

export type ChatUploadInfo = {
  upload_id: string;
  filename: string;
  mime_type: string;
  size_bytes: number;
  uploaded_bytes: number;
  chunk_size_bytes: number;
  status: ChatUploadStatus;
  expires_at: string;
};

type ChatUploadResponse = {
  upload: ChatUploadInfo;
};

export class UploadAbortedError extends Error {
  constructor(message = 'Upload aborted.') {
    super(message);
    this.name = 'UploadAbortedError';
  }
}

class UploadNetworkError extends Error {
  constructor(message = 'Upload request failed.') {
    super(message);
    this.name = 'UploadNetworkError';
  }
}

const RETRYABLE_UPLOAD_HTTP_STATUS_CODES = new Set([408, 425, 429, 500, 502, 503, 504]);

export const isRetryableUploadChunkError = (error: unknown) => {
  if (error instanceof UploadNetworkError) {
    return true;
  }

  return isHttpError(error) && RETRYABLE_UPLOAD_HTTP_STATUS_CODES.has(error.status);
};

export const createChatUploadSession = async (chatId: number, file: File) => {
  const payload = await api.post<ChatUploadResponse>(`/api/bff/chats/${chatId}/uploads`, {
    filename: file.name,
    mime_type: file.type || 'application/octet-stream',
    size_bytes: file.size,
  });

  return payload.upload;
};

export const getChatUploadSession = async (chatId: number, uploadId: string) => {
  const payload = await api.get<ChatUploadResponse>(`/api/bff/chats/${chatId}/uploads/${uploadId}`);
  return payload.upload;
};

export const abortChatUploadSession = async (chatId: number, uploadId: string) => {
  const payload = await api.del<ChatUploadResponse>(`/api/bff/chats/${chatId}/uploads/${uploadId}`);
  return payload.upload;
};

export const uploadChatChunk = (
  chatId: number,
  uploadId: string,
  offset: number,
  chunk: Blob,
  options: {
    onProgress?: (loadedBytes: number) => void;
    onAbortHandle?: (abortHandle: (() => void) | null) => void;
  } = {}
) =>
  new Promise<ChatUploadInfo>((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    const csrf = getCsrfToken();

    xhr.open('PUT', `/api/bff/chats/${chatId}/uploads/${uploadId}/chunk`);
    xhr.responseType = 'text';
    xhr.withCredentials = true;
    xhr.setRequestHeader('accept', 'application/json');
    xhr.setRequestHeader('content-type', 'application/octet-stream');
    xhr.setRequestHeader('x-upload-offset', String(offset));
    if (csrf) xhr.setRequestHeader('x-csrf-token', csrf);

    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable) {
        options.onProgress?.(event.loaded);
      }
    };

    xhr.onload = () => {
      options.onAbortHandle?.(null);
      const bodyText = typeof xhr.responseText === 'string' ? xhr.responseText : '';
      const bodyJson = parseJson(bodyText);

      if (xhr.status >= 200 && xhr.status < 300) {
        const payload = bodyJson as ChatUploadResponse | null;
        if (payload?.upload) {
          resolve(payload.upload);
          return;
        }

        reject(new Error('Upload response is invalid.'));
        return;
      }

      reject(
        new HttpError({
          status: xhr.status,
          statusText: xhr.statusText || 'Upload failed',
          bodyText,
          bodyJson,
        })
      );
    };

    xhr.onerror = () => {
      options.onAbortHandle?.(null);
      reject(new UploadNetworkError());
    };

    xhr.onabort = () => {
      options.onAbortHandle?.(null);
      reject(new UploadAbortedError());
    };

    options.onAbortHandle?.(() => xhr.abort());
    xhr.send(chunk);
  });

const parseJson = (value: string) => {
  const trimmed = value.trim();
  if (trimmed === '') return null;

  try {
    return JSON.parse(trimmed) as unknown;
  } catch {
    return null;
  }
};
