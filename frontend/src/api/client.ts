import {
  clearBackendStatusBanner,
  showBackendStatusBanner,
} from '@/features/app/backendStatusBanner';
import { getEffectiveLocale, translate } from '@/i18n';

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
    return translate('Request body is too large. Try a smaller upload.');
  }

  return asNonEmptyString(statusText) || translate('Request failed with status {status}.', { status });
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
  timeoutMs?: number | null;
  retry?: false | {
    attempts?: number;
    delaysMs?: number[];
  };
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

class RequestTimeoutError extends Error {
  constructor() {
    super(translate('The request timed out. Check your connection and try again.'));
    this.name = 'RequestTimeoutError';
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

function createAbortError(): DOMException {
  return new DOMException('The operation was aborted.', 'AbortError');
}

function genericServerBannerMessage(status: number): string {
  if ([502, 503, 504].includes(status)) {
    return translate('The server is temporarily unavailable. Please try again.');
  }

  return translate('The server returned an unexpected error. Please try again.');
}

function genericClientBannerMessage(status: number): string {
  switch (status) {
    case 400:
      return translate('The server could not process this request. Review the input and try again.');
    case 401:
      return translate('Your session is no longer valid. Sign in and try again.');
    case 403:
      return translate('You do not have permission to perform this action.');
    case 404:
      return translate('The requested resource could not be found.');
    case 409:
      return translate('This request conflicts with the current server state. Refresh and try again.');
    case 422:
      return translate('The submitted data is invalid. Review the fields and try again.');
    case 429:
      return translate('Too many requests were sent. Wait a moment and try again.');
    default:
      return translate('The request could not be completed. Review the input and try again.');
  }
}

function normalizeMessage(value: string): string {
  return value.trim().replace(/\s+/g, ' ');
}

function buildClientBannerMessage(error: HttpError): string {
  const detail = normalizeMessage(getApiErrorMessage(error, genericClientBannerMessage(error.status)));
  const statusText = normalizeMessage(error.statusText);

  if (
    detail === '' ||
    detail === statusText ||
    detail === `Request failed with status ${error.status}.`
  ) {
    return genericClientBannerMessage(error.status);
  }

  return detail;
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

function buildHttpBanner(error: HttpError): { title: string; message: string } | null {
  if (error.status >= 500) {
    return {
      title: translate('Server error'),
      message: buildServerBannerMessage(error),
    };
  }

  if (error.status >= 400) {
    return {
      title: translate('Request error'),
      message: buildClientBannerMessage(error),
    };
  }

  return null;
}

function buildNetworkBannerMessage(error: unknown): string {
  const fallback = translate('The request could not reach the server. Check your connection and try again.');

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

const DEFAULT_READ_TIMEOUT_MS = 10_000;
const DEFAULT_WRITE_TIMEOUT_MS = 30_000;
const DEFAULT_RETRY_ATTEMPTS = 2;
const DEFAULT_RETRY_DELAYS_MS = [500, 1_500] as const;
const RETRYABLE_HTTP_STATUS_CODES = new Set([408, 425, 429, 500, 502, 503, 504]);

type ResolvedRetryOptions = {
  attempts: number;
  delaysMs: number[];
};

type AttemptSignal = {
  signal?: AbortSignal;
  didTimeout: () => boolean;
  cleanup: () => void;
};

function normalizeNonNegativeInteger(value: unknown, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value)
    ? Math.max(0, Math.floor(value))
    : fallback;
}

function normalizeDelayMs(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value)
    ? Math.max(0, Math.floor(value))
    : null;
}

function resolveTimeoutMs(value: number | null | undefined, isWrite: boolean): number | null {
  if (value === null) return null;
  return normalizeDelayMs(value) ?? (isWrite ? DEFAULT_WRITE_TIMEOUT_MS : DEFAULT_READ_TIMEOUT_MS);
}

function resolveRetryOptions(
  retry: ApiRequestOptions['retry'],
  isWrite: boolean
): ResolvedRetryOptions {
  if (retry === false) return { attempts: 0, delaysMs: [...DEFAULT_RETRY_DELAYS_MS] };

  if (retry && typeof retry === 'object') {
    const delays = Array.isArray(retry.delaysMs)
      ? retry.delaysMs.map(normalizeDelayMs).filter((delay): delay is number => delay !== null)
      : [];

    return {
      attempts: normalizeNonNegativeInteger(retry.attempts, DEFAULT_RETRY_ATTEMPTS),
      delaysMs: delays.length ? delays : [...DEFAULT_RETRY_DELAYS_MS],
    };
  }

  return {
    attempts: isWrite ? 0 : DEFAULT_RETRY_ATTEMPTS,
    delaysMs: [...DEFAULT_RETRY_DELAYS_MS],
  };
}

function retryDelayMs(retry: ResolvedRetryOptions, attemptIndex: number): number {
  return retry.delaysMs[Math.min(attemptIndex, retry.delaysMs.length - 1)] ?? 0;
}

function shouldRetryError(error: unknown): boolean {
  if (isHttpError(error)) return RETRYABLE_HTTP_STATUS_CODES.has(error.status);
  if (error instanceof Error && error.name === 'RequestTimeoutError') return true;
  if (isAbortError(error)) return false;
  return true;
}

function createAttemptSignal(externalSignal: AbortSignal | null | undefined, timeoutMs: number | null): AttemptSignal {
  if (timeoutMs === null && !externalSignal) {
    return { didTimeout: () => false, cleanup: () => {} };
  }

  if (timeoutMs === null) {
    return {
      signal: externalSignal ?? undefined,
      didTimeout: () => false,
      cleanup: () => {},
    };
  }

  const controller = new AbortController();
  let timedOut = false;
  let timeoutId: number | null = window.setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);

  let abortFromExternalSignal: (() => void) | null = null;

  if (externalSignal?.aborted) {
    controller.abort();
  } else if (externalSignal) {
    abortFromExternalSignal = () => controller.abort();
    externalSignal.addEventListener('abort', abortFromExternalSignal, { once: true });
  }

  return {
    signal: controller.signal,
    didTimeout: () => timedOut,
    cleanup: () => {
      if (timeoutId !== null) {
        window.clearTimeout(timeoutId);
        timeoutId = null;
      }

      if (abortFromExternalSignal && externalSignal) {
        externalSignal.removeEventListener('abort', abortFromExternalSignal);
      }
    },
  };
}

function waitForRetry(delayMs: number, signal: AbortSignal | null | undefined): Promise<void> {
  if (signal?.aborted) return Promise.reject(createAbortError());

  return new Promise((resolve, reject) => {
    let timeoutId: number | null = null;

    const abort = () => {
      if (timeoutId !== null) window.clearTimeout(timeoutId);
      signal?.removeEventListener('abort', abort);
      reject(createAbortError());
    };

    timeoutId = window.setTimeout(() => {
      signal?.removeEventListener('abort', abort);
      resolve();
    }, delayMs);

    signal?.addEventListener('abort', abort, { once: true });
  });
}

async function fetchWithTimeout(
  path: string,
  requestOptions: RequestInit,
  externalSignal: AbortSignal | null | undefined,
  timeoutMs: number | null
): Promise<Response> {
  const attemptSignal = createAttemptSignal(externalSignal, timeoutMs);

  try {
    return await fetch(path, {
      ...requestOptions,
      signal: attemptSignal.signal,
    });
  } catch (error) {
    if (attemptSignal.didTimeout() && isAbortError(error) && !externalSignal?.aborted) {
      throw new RequestTimeoutError();
    }

    throw error;
  } finally {
    attemptSignal.cleanup();
  }
}

async function buildHttpError(response: Response): Promise<HttpError> {
  const bodyText = await response.text().catch(() => '');
  let bodyJson: unknown | null = null;
  if (bodyText) {
    try {
      bodyJson = JSON.parse(bodyText) as unknown;
    } catch {
      bodyJson = null;
    }
  }

  return new HttpError({
    status: response.status,
    statusText: response.statusText,
    bodyText,
    bodyJson,
  });
}

async function request<T>(path: string, options: ApiRequestOptions = {}): Promise<T> {
  const {
    redirectOnUnauthorized = true,
    showErrorBanner = true,
    timeoutMs,
    retry,
    signal,
    ...requestOptions
  } = options;
  const headers = new Headers(requestOptions.headers || {});
  if (!headers.has('accept')) headers.set('accept', 'application/json');
  if (path.startsWith('/api/bff') && !headers.has('x-ui-locale')) {
    headers.set('x-ui-locale', getEffectiveLocale());
  }

  const method = (requestOptions.method || 'GET').toUpperCase();
  const isWrite = !['GET', 'HEAD', 'OPTIONS'].includes(method);
  const resolvedTimeoutMs = resolveTimeoutMs(timeoutMs, isWrite);
  const resolvedRetry = resolveRetryOptions(retry, isWrite);
  const isFormData =
    typeof FormData !== 'undefined' && requestOptions.body instanceof FormData;

  if (isWrite) {
    const token = getCsrfToken();
    if (token) headers.set('x-csrf-token', token);
    if (!headers.has('content-type') && !isFormData) headers.set('content-type', 'application/json');
  }

  for (let attemptIndex = 0; ; attemptIndex += 1) {
    let response: Response;

    try {
      response = await fetchWithTimeout(
        path,
        {
          ...requestOptions,
          method,
          headers,
          credentials: 'same-origin',
        },
        signal,
        resolvedTimeoutMs
      );
    } catch (error) {
      if (isAbortError(error)) throw error;

      if (shouldRetryError(error) && attemptIndex < resolvedRetry.attempts) {
        await waitForRetry(retryDelayMs(resolvedRetry, attemptIndex), signal);
        continue;
      }

      if (showErrorBanner) {
        showBackendStatusBanner({
          title: translate('Connection problem'),
          message: buildNetworkBannerMessage(error),
        });
      }

      throw error;
    }

    if (!response.ok) {
      const error = await buildHttpError(response);

      if (shouldRetryError(error) && attemptIndex < resolvedRetry.attempts) {
        await waitForRetry(retryDelayMs(resolvedRetry, attemptIndex), signal);
        continue;
      }

      if (response.status === 401 && redirectOnUnauthorized) {
        window.location.assign('/login');
      }

      const httpBanner =
        showErrorBanner && !(response.status === 401 && redirectOnUnauthorized)
          ? buildHttpBanner(error)
          : null;

      if (httpBanner) {
        showBackendStatusBanner(httpBanner);
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
