import { api } from './client';
import type { ImageAsset } from '@/types/api';

export type ImageMutationResponse = {
  image: ImageAsset | null;
};

function buildImageFormData(file: File) {
  const formData = new FormData();
  formData.append('file', file);
  return formData;
}

export function uploadBotImage(id: number, file: File) {
  return api.post<ImageMutationResponse>(`/api/bff/bots/${id}/image`, buildImageFormData(file));
}

export function deleteBotImage(id: number) {
  return api.del<ImageMutationResponse>(`/api/bff/bots/${id}/image`);
}

export function uploadKnowledgeBlockImage(id: number, file: File) {
  return api.post<ImageMutationResponse>(
    `/api/bff/knowledge-blocks/${id}/image`,
    buildImageFormData(file)
  );
}

export function deleteKnowledgeBlockImage(id: number) {
  return api.del<ImageMutationResponse>(`/api/bff/knowledge-blocks/${id}/image`);
}
