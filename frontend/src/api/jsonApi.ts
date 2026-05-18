import { api, isHttpError, type HttpError } from './client';

export type JsonApiErrorObject = {
  id?: string;
  status?: string;
  code?: string;
  title?: string;
  detail?: string;
  source?: { pointer?: string; parameter?: string };
  meta?: unknown;
};

type JsonApiRelationshipData =
  | { type: string; id: string }
  | Array<{ type: string; id: string }>
  | null;

export type JsonApiResource<TAttributes extends Record<string, unknown> = Record<string, unknown>> = {
  id: string;
  type: string;
  attributes?: TAttributes;
  relationships?: Record<string, { data?: JsonApiRelationshipData }>;
};

type JsonApiDocument<TData> = {
  data: TData;
  included?: JsonApiResource[];
  meta?: unknown;
  links?: unknown;
};

export type JsonApiIncludedIndex = Map<string, JsonApiResource>;

export type JsonApiListResponse<TAttributes extends Record<string, unknown> = Record<string, unknown>> =
  JsonApiDocument<Array<JsonApiResource<TAttributes>>>;

export type JsonApiSingleResponse<TAttributes extends Record<string, unknown> = Record<string, unknown>> =
  JsonApiDocument<JsonApiResource<TAttributes>>;

export type JsonApiMutationResponse<TAttributes extends Record<string, unknown> = Record<string, unknown>> =
  JsonApiSingleResponse<TAttributes>;

type JsonApiErrorResponse = { errors: JsonApiErrorObject[] };

function isJsonApiErrorResponse(value: unknown): value is JsonApiErrorResponse {
  if (!value || typeof value !== 'object') return false;
  const v = value as { errors?: unknown };
  return Array.isArray(v.errors);
}

export function getJsonApiErrors(error: unknown): JsonApiErrorObject[] | null {
  if (!isHttpError(error)) return null;
  const httpError = error as HttpError;
  if (!isJsonApiErrorResponse(httpError.bodyJson)) return null;
  return httpError.bodyJson.errors;
}

function jsonApiHeaders(): HeadersInit {
  return {
    accept: 'application/vnd.api+json',
    'content-type': 'application/vnd.api+json',
  };
}

export function toIntId(id: string | number | null | undefined): number | null {
  if (typeof id === 'number' && Number.isFinite(id)) return id;
  if (typeof id !== 'string') return null;
  const parsed = Number(id);
  return Number.isFinite(parsed) ? parsed : null;
}

export function relationshipId(resource: JsonApiResource, relName: string): number | null {
  const rel = resource.relationships?.[relName];
  const data = rel?.data;
  if (!data || Array.isArray(data)) return null;
  return toIntId(data.id);
}

function jsonApiResourceKey(type: string, id: string | number): string {
  return `${String(type)}:${String(id)}`;
}

export function createJsonApiIncludedIndex(included?: JsonApiResource[] | null): JsonApiIncludedIndex {
  const index: JsonApiIncludedIndex = new Map();

  for (const resource of included || []) {
    if (!resource?.type || resource.id == null) continue;
    index.set(jsonApiResourceKey(resource.type, resource.id), resource);
  }

  return index;
}

export function relatedResource(
  resource: JsonApiResource,
  relName: string,
  includedIndex: JsonApiIncludedIndex
): JsonApiResource | null {
  const rel = resource.relationships?.[relName];
  const data = rel?.data;
  if (!data || Array.isArray(data)) return null;
  return includedIndex.get(jsonApiResourceKey(data.type, data.id)) ?? null;
}

export function relatedResources(
  resource: JsonApiResource,
  relName: string,
  includedIndex: JsonApiIncludedIndex
): JsonApiResource[] {
  const rel = resource.relationships?.[relName];
  const data = rel?.data;
  if (!Array.isArray(data)) return [];

  return data
    .map((item) => includedIndex.get(jsonApiResourceKey(item.type, item.id)) ?? null)
    .filter((item): item is JsonApiResource => Boolean(item));
}

export type FieldErrors = Record<string, string[]>;

export function fieldErrorsFromJsonApiErrors(errors: JsonApiErrorObject[]): FieldErrors {
  const out: FieldErrors = {};

  for (const err of errors || []) {
    const pointer = err.source?.pointer || '';
    const detail = (err.detail || err.title || 'Invalid value').trim();
    const match = pointer.match(/^\/data\/attributes\/(.+)$/);
    const field = match?.[1];

    if (!field) continue;
    out[field] ||= [];
    out[field].push(detail);
  }

  return out;
}

export function formErrorsFromJsonApiErrors(errors: JsonApiErrorObject[]): string[] {
  const out: string[] = [];
  for (const err of errors || []) {
    if (err.source?.pointer) continue;
    const message = (err.detail || err.title || '').trim();
    if (message) out.push(message);
  }
  return out;
}

export async function jsonApiList<TAttributes extends Record<string, unknown> = Record<string, unknown>>(
  path: string,
  params?: URLSearchParams
): Promise<JsonApiListResponse<TAttributes>> {
  const qs = params?.toString();
  const url = qs ? `${path}?${qs}` : path;
  return api.get<JsonApiListResponse<TAttributes>>(url, { headers: jsonApiHeaders() });
}

export async function jsonApiGet<TAttributes extends Record<string, unknown> = Record<string, unknown>>(
  path: string,
  params?: URLSearchParams
): Promise<JsonApiSingleResponse<TAttributes>> {
  const qs = params?.toString();
  const url = qs ? `${path}?${qs}` : path;
  return api.get<JsonApiSingleResponse<TAttributes>>(url, { headers: jsonApiHeaders() });
}

export async function jsonApiCreate<TAttributes extends Record<string, unknown> = Record<string, unknown>>(
  basePath: string,
  type: string,
  attributes: Record<string, unknown>,
  params?: URLSearchParams
): Promise<JsonApiMutationResponse<TAttributes>> {
  const qs = params?.toString();
  const url = qs ? `${basePath}?${qs}` : basePath;
  return api.post<JsonApiMutationResponse<TAttributes>>(
    url,
    { data: { type, attributes } },
    { headers: jsonApiHeaders() }
  );
}

export async function jsonApiUpdate<TAttributes extends Record<string, unknown> = Record<string, unknown>>(
  basePath: string,
  type: string,
  id: number,
  attributes: Record<string, unknown>,
  params?: URLSearchParams
): Promise<JsonApiMutationResponse<TAttributes>> {
  const qs = params?.toString();
  const url = qs ? `${basePath}/${id}?${qs}` : `${basePath}/${id}`;
  return api.patch<JsonApiMutationResponse<TAttributes>>(
    url,
    { data: { type, id: String(id), attributes } },
    { headers: jsonApiHeaders() }
  );
}

export async function jsonApiDelete(basePath: string, id: number): Promise<void> {
  await api.del(`${basePath}/${id}`, { headers: jsonApiHeaders() });
}
