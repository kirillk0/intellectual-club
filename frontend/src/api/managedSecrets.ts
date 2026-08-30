import { api, type ApiRequestOptions } from './client';

export type ManagedSecretAttachment = {
  id: number;
  external_id: string;
  name: string;
  description: string;
  env_name: string;
};

export type ManagedSecretsResponse = {
  secret?: ManagedSecretAttachment;
  secrets: ManagedSecretAttachment[];
};

export type SecretAttachmentParent = 'knowledge-blocks' | 'tool-instances';

export type ManagedSecretInput = {
  name: string;
  description: string;
  env_name: string;
  value?: string;
};

function secretPath(parent: SecretAttachmentParent, parentId: number, secretId?: number) {
  const base = `/api/bff/${parent}/${parentId}/secrets`;
  return secretId ? `${base}/${secretId}` : base;
}

export function listManagedSecrets(
  parent: SecretAttachmentParent,
  parentId: number,
  options?: ApiRequestOptions
) {
  return api.get<ManagedSecretsResponse>(secretPath(parent, parentId), options);
}

export function createManagedSecret(
  parent: SecretAttachmentParent,
  parentId: number,
  attrs: ManagedSecretInput & { value: string }
) {
  return api.post<ManagedSecretsResponse>(secretPath(parent, parentId), attrs);
}

export function updateManagedSecret(
  parent: SecretAttachmentParent,
  parentId: number,
  secretId: number,
  attrs: ManagedSecretInput
) {
  return api.patch<ManagedSecretsResponse>(secretPath(parent, parentId, secretId), attrs);
}

export function deleteManagedSecret(
  parent: SecretAttachmentParent,
  parentId: number,
  secretId: number
) {
  return api.del<ManagedSecretsResponse>(secretPath(parent, parentId, secretId));
}
