function getCsrfToken(): string | null {
  const meta = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]');
  return meta?.content || null;
}

export type ApiRequestOptions = RequestInit & {
  redirectOnUnauthorized?: boolean;
};

export class HttpError extends Error {
  status: number;
  statusText: string;
  bodyText: string;
  bodyJson: unknown | null;

  constructor(params: { status: number; statusText: string; bodyText: string; bodyJson: unknown | null }) {
    const message = `HTTP ${params.status}: ${params.bodyText || params.statusText}`;
    super(message);
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

async function request<T>(path: string, options: ApiRequestOptions = {}): Promise<T> {
  const { redirectOnUnauthorized = true, ...requestOptions } = options;
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

  const response = await fetch(path, {
    ...requestOptions,
    method,
    headers,
    credentials: 'same-origin',
  });

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

    throw new HttpError({
      status: response.status,
      statusText: response.statusText,
      bodyText,
      bodyJson,
    });
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
