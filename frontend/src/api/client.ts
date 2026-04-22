import {
  clearBackendStatusBanner,
  showBackendStatusBanner,
} from '@/features/app/backendStatusBanner';

export function getCsrfToken(): string | null {
  const meta = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]');
  return meta?.content || null;
}

function asNonEmptyString(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed === '' ? null : trimmed;
}

function looksLikeHtml(value: string): boolean {
  return /<(?:!doctype|html|head|body|title|script|style)\b/i.test(value);
}

function extractMessageFromBodyJson(bodyJson: unknown): string | null {
  if (!bodyJson || typeof bodyJson !== 'object') return null;

  const payload = bodyJson as {
    error?: unknown;
    detail?: unknown;
    message?: unknown;
    errors?: unknown;
  };

  const directMessage =
    asNonEmptyString(payload.error) ||
    asNonEmptyString(payload.detail) ||
    asNonEmptyString(payload.message);

  if (directMessage) return directMessage;

  if (Array.isArray(payload.errors)) {
    for (const item of payload.errors) {
      if (!item || typeof item !== 'object') continue;
      const entry = item as { detail?: unknown; title?: unknown; message?: unknown };
      const message =
        asNonEmptyString(entry.detail) ||
        asNonEmptyString(entry.title) ||
        asNonEmptyString(entry.message);
      if (message) return message;
    }
  }

  if (payload.errors && typeof payload.errors === 'object') {
    const errors = payload.errors as { detail?: unknown; title?: unknown; message?: unknown };
    return (
      asNonEmptyString(errors.detail) ||
      asNonEmptyString(errors.title) ||
      asNonEmptyString(errors.message)
    );
  }

  return null;
}

function extractMessageFromBodyText(bodyText: string): string | null {
  const trimmed = bodyText.trim();
  if (trimmed === '' || looksLikeHtml(trimmed)) return null;

  const normalized = trimmed.replace(/\s+/g, ' ');
  if (normalized.length <= 240) return normalized;
  return `${normalized.slice(0, 237).trimEnd()}...`;
}

function defaultMessageForStatus(status: number, statusText: string): string {
  if (status === 413) {
    return 'Request body is too large. Try a smaller upload.';
  }

  return asNonEmptyString(statusText) || `Request failed with status ${status}.`;
}

function buildHttpErrorMessage(params: {
  status: number;
  statusText: string;
  bodyText: string;
  bodyJson: unknown | null;
}): string {
  const detail =
    extractMessageFromBodyJson(params.bodyJson) ||
    extractMessageFromBodyText(params.bodyText) ||
    defaultMessageForStatus(params.status, params.statusText);

  return `HTTP ${params.status}: ${detail}`;
}

export type ApiRequestOptions = RequestInit & {
  redirectOnUnauthorized?: boolean;
  showErrorBanner?: boolean;
};

export class HttpError extends Error {
  status: number;
  statusText: string;
  bodyText: string;
  bodyJson: unknown | null;

  constructor(params: { status: number; statusText: string; bodyText: string; bodyJson: unknown | null }) {
    super(buildHttpErrorMessage(params));
    this.name = 'HttpError';
    this.status = params.status;
    this.statusText = params.statusText;
    this.bodyText = params.bodyText;
    this.bodyJson = params.bodyJson;
  }
}

export function isHttpError(error: unknown): error is HttpError {
  return error instanceof Error && (error as HttpError).name === 'HttpError';
}

export function getApiErrorMessage(error: unknown, fallback: string): string {
  if (isHttpError(error)) {
    return (
      extractMessageFromBodyJson(error.bodyJson) ||
      extractMessageFromBodyText(error.bodyText) ||
      defaultMessageForStatus(error.status, error.statusText)
    );
  }

  return error instanceof Error && error.message.trim() !== '' ? error.message : fallback;
}

function isAbortError(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError';
}

function genericServerBannerMessage(status: number): string {
  if ([502, 503, 504].includes(status)) {
    return 'The server is temporarily unavailable. Please try again.';
  }

  return 'The server returned an unexpected error. Please try again.';
}

function normalizeMessage(value: string): string {
  return value.trim().replace(/\s+/g, ' ');
}

function buildServerBannerMessage(error: HttpError): string {
  const detail = normalizeMessage(getApiErrorMessage(error, genericServerBannerMessage(error.status)));
  const statusText = normalizeMessage(error.statusText);

  if (
    detail === '' ||
    detail === statusText ||
    detail === `Request failed with status ${error.status}.`
  ) {
    return genericServerBannerMessage(error.status);
  }

  return detail;
}

function buildNetworkBannerMessage(error: unknown): string {
  const fallback = 'The request could not reach the server. Check your connection and try again.';

  if (!(error instanceof Error)) return fallback;

  const message = normalizeMessage(error.message);

  if (
    message === '' ||
    message === 'Failed to fetch' ||
    message === 'NetworkError when attempting to fetch resource.'
  ) {
    return fallback;
  }

  return message;
}

async function request<T>(path: string, options: ApiRequestOptions = {}): Promise<T> {
  const {
    redirectOnUnauthorized = true,
    showErrorBanner = true,
    ...requestOptions
  } = options;
  const headers = new Headers(requestOptions.headers || {});
  if (!headers.has('accept')) headers.set('accept', 'application/json');

  const method = (requestOptions.method || 'GET').toUpperCase();
  const isWrite = !['GET', 'HEAD', 'OPTIONS'].includes(method);
  const isFormData =
    typeof FormData !== 'undefined' && requestOptions.body instanceof FormData;

  if (isWrite) {
    const token = getCsrfToken();
    if (token) headers.set('x-csrf-token', token);
    if (!headers.has('content-type') && !isFormData) headers.set('content-type', 'application/json');
  }

  let response: Response;

  try {
    response = await fetch(path, {
      ...requestOptions,
      method,
      headers,
      credentials: 'same-origin',
    });
  } catch (error) {
    if (!isAbortError(error) && showErrorBanner) {
      showBackendStatusBanner({
        title: 'Connection problem',
        message: buildNetworkBannerMessage(error),
      });
    }

    throw error;
  }

  if (!response.ok) {
    const bodyText = await response.text().catch(() => '');
    let bodyJson: unknown | null = null;
    if (bodyText) {
      try {
        bodyJson = JSON.parse(bodyText) as unknown;
      } catch {
        bodyJson = null;
      }
    }

    if (response.status === 401 && redirectOnUnauthorized) {
      window.location.assign('/login');
    }

    const error = new HttpError({
      status: response.status,
      statusText: response.statusText,
      bodyText,
      bodyJson,
    });

    if (response.status >= 500 && showErrorBanner) {
      showBackendStatusBanner({
        title: 'Server error',
        message: buildServerBannerMessage(error),
      });
    }

    throw error;
  }

  if (showErrorBanner) {
    clearBackendStatusBanner();
  }

  if (response.status === 204) return undefined as T;

  const bodyText = await response.text().catch(() => '');
  if (!bodyText) return undefined as T;

  try {
    return JSON.parse(bodyText) as T;
  } catch {
    return undefined as T;
  }
}

export const api = {
  get: <T>(path: string, options?: ApiRequestOptions) => request<T>(path, options),
  post: <T>(path: string, body: unknown, options: ApiRequestOptions = {}) =>
    request<T>(path, {
      ...options,
      method: 'POST',
      body:
        typeof FormData !== 'undefined' && body instanceof FormData ? body : JSON.stringify(body),
    }),
  put: <T>(path: string, body: unknown, options: ApiRequestOptions = {}) =>
    request<T>(path, {
      ...options,
      method: 'PUT',
      body:
        typeof FormData !== 'undefined' && body instanceof FormData ? body : JSON.stringify(body),
    }),
  patch: <T>(path: string, body: unknown, options: ApiRequestOptions = {}) =>
    request<T>(path, {
      ...options,
      method: 'PATCH',
      body:
        typeof FormData !== 'undefined' && body instanceof FormData ? body : JSON.stringify(body),
    }),
  del: <T>(path: string, options: ApiRequestOptions = {}) => request<T>(path, { ...options, method: 'DELETE' }),
};
