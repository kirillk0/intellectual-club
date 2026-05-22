import { api, getCsrfToken, HttpError } from './client';

export type MarkdownImportAction = 'import' | 'update' | 'create_new' | 'skip';

export type MarkdownImportExistingBlock = {
  id: number;
  external_id: string;
  name: string;
  version: string | null;
};

export type MarkdownImportItem = {
  key: string;
  filename: string;
  name: string;
  external_id: string | null;
  existing_block: MarkdownImportExistingBlock | null;
  available_actions: MarkdownImportAction[];
  default_action: MarkdownImportAction;
};

export type MarkdownImportPreviewResponse = {
  items: MarkdownImportItem[];
};

export type MarkdownImportSummary = {
  imported: number;
  updated: number;
  created: number;
  skipped: number;
  items: Array<{
    key: string;
    filename: string;
    action: MarkdownImportAction;
    status: 'created' | 'updated' | 'skipped' | string;
    block_id?: number;
    external_id?: string | null;
  }>;
};

type ArchiveResponse = {
  blob: Blob;
  filename: string;
};

function buildImportFormData(tagId: number, files: File[]) {
  const formData = new FormData();
  formData.append('tag_id', String(tagId));
  for (const file of files) formData.append('files[]', file);
  return formData;
}

function parseContentDispositionFilename(value: string | null) {
  if (!value) return null;

  const encoded = value.match(/filename\*=UTF-8''([^;]+)/i)?.[1];
  if (encoded) {
    try {
      return decodeURIComponent(encoded.replace(/^"|"$/g, ''));
    } catch {
      return encoded.replace(/^"|"$/g, '');
    }
  }

  return value.match(/filename="([^"]+)"/i)?.[1] || value.match(/filename=([^;]+)/i)?.[1]?.trim() || null;
}

async function buildHttpError(response: Response) {
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

export async function exportKnowledgeBlocksMarkdownArchive(
  tagId: number,
  blockIds: number[]
): Promise<ArchiveResponse> {
  const headers = new Headers({
    accept: 'application/zip',
    'content-type': 'application/json',
  });
  const csrf = getCsrfToken();
  if (csrf) headers.set('x-csrf-token', csrf);

  const response = await fetch('/api/bff/knowledge-blocks/markdown-export', {
    method: 'POST',
    headers,
    credentials: 'same-origin',
    body: JSON.stringify({ tag_id: tagId, block_ids: blockIds }),
  });

  if (!response.ok) {
    throw await buildHttpError(response);
  }

  return {
    blob: await response.blob(),
    filename:
      parseContentDispositionFilename(response.headers.get('content-disposition')) || 'Knowledge Blocks.zip',
  };
}

export function previewKnowledgeBlocksMarkdownImport(tagId: number, files: File[]) {
  return api.post<MarkdownImportPreviewResponse>(
    '/api/bff/knowledge-blocks/markdown-import/preview',
    buildImportFormData(tagId, files)
  );
}

export function importKnowledgeBlocksMarkdown(params: {
  tagId: number;
  files: File[];
  version: string;
  decisions: Record<string, MarkdownImportAction>;
}) {
  const formData = buildImportFormData(params.tagId, params.files);
  formData.append('version', params.version);
  formData.append('decisions', JSON.stringify(params.decisions));

  return api.post<MarkdownImportSummary>('/api/bff/knowledge-blocks/markdown-import', formData);
}
