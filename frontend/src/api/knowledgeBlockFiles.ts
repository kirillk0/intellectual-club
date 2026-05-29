import { api } from './client';
import type { KnowledgeBlockAttachment } from '@/types/api';

export type KnowledgeBlockFilesResponse = {
  attachment?: KnowledgeBlockAttachment;
  attachments: KnowledgeBlockAttachment[];
};

function buildFileFormData(file: File) {
  const formData = new FormData();
  formData.append('file', file);
  return formData;
}

export function listKnowledgeBlockFiles(id: number) {
  return api.get<KnowledgeBlockFilesResponse>(`/api/bff/knowledge-blocks/${id}/files`);
}

export function uploadKnowledgeBlockFile(id: number, file: File) {
  return api.post<KnowledgeBlockFilesResponse>(
    `/api/bff/knowledge-blocks/${id}/files`,
    buildFileFormData(file)
  );
}

export async function uploadKnowledgeBlockFiles(id: number, files: File[]) {
  let response: KnowledgeBlockFilesResponse | null = null;

  for (const file of files) {
    response = await uploadKnowledgeBlockFile(id, file);
  }

  return response ?? listKnowledgeBlockFiles(id);
}

export function deleteKnowledgeBlockFile(id: number, attachmentId: number) {
  return api.del<KnowledgeBlockFilesResponse>(`/api/bff/knowledge-blocks/${id}/files/${attachmentId}`);
}
