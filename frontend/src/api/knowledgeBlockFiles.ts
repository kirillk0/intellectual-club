import { api } from './client';
import type { KnowledgeBlockAttachment } from '@/types/api';

export type KnowledgeBlockFilesResponse = {
  attachment?: KnowledgeBlockAttachment;
  attachments: KnowledgeBlockAttachment[];
};

type UploadKnowledgeBlockFileOptions = {
  enabled?: boolean;
};

function buildFileFormData(file: File, options: UploadKnowledgeBlockFileOptions = {}) {
  const formData = new FormData();
  formData.append('file', file);
  if (typeof options.enabled === 'boolean') formData.append('enabled', String(options.enabled));
  return formData;
}

export function listKnowledgeBlockFiles(id: number) {
  return api.get<KnowledgeBlockFilesResponse>(`/api/bff/knowledge-blocks/${id}/files`);
}

export function uploadKnowledgeBlockFile(id: number, file: File, options: UploadKnowledgeBlockFileOptions = {}) {
  return api.post<KnowledgeBlockFilesResponse>(
    `/api/bff/knowledge-blocks/${id}/files`,
    buildFileFormData(file, options)
  );
}

export async function uploadKnowledgeBlockFiles(
  id: number,
  files: File[],
  options: UploadKnowledgeBlockFileOptions = {}
) {
  let response: KnowledgeBlockFilesResponse | null = null;

  for (const file of files) {
    response = await uploadKnowledgeBlockFile(id, file, options);
  }

  return response ?? listKnowledgeBlockFiles(id);
}

export function deleteKnowledgeBlockFile(id: number, attachmentId: number) {
  return api.del<KnowledgeBlockFilesResponse>(`/api/bff/knowledge-blocks/${id}/files/${attachmentId}`);
}

export function updateKnowledgeBlockFile(id: number, attachmentId: number, attrs: { enabled: boolean }) {
  return api.patch<KnowledgeBlockFilesResponse>(`/api/bff/knowledge-blocks/${id}/files/${attachmentId}`, attrs);
}
