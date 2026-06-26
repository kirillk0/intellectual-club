import { api } from './client';
import {
  createJsonApiIncludedIndex,
  jsonApiCreate,
  jsonApiDelete,
  jsonApiGet,
  jsonApiList,
  jsonApiUpdate,
  relatedResources,
  toIntId,
  type JsonApiMutationResponse,
  type JsonApiResource,
} from './jsonApi';
import type { AdminUser, AdminUserGroup, AdminUserGroupSummary } from '@/types/api';

const USERS_BASE_PATH = '/api/ash/users';
const USER_GROUPS_BASE_PATH = '/api/ash/user-groups';
const USER_TYPE = 'users';
const USER_GROUP_TYPE = 'user-groups';

type AdminUserInput = {
  username: string;
  is_admin: boolean;
  group_ids: number[];
  password?: string;
  password_confirmation?: string;
};

type AdminUserGroupInput = {
  name: string;
  user_ids: number[];
};

type AdminUserSummary = {
  id: number;
  username: string;
  is_admin: boolean;
};

function jsonApiHeaders(): HeadersInit {
  return {
    accept: 'application/vnd.api+json',
    'content-type': 'application/vnd.api+json',
  };
}

function userDocumentParams() {
  const params = new URLSearchParams();
  params.set('include', 'groups');
  return params;
}

function userListParams() {
  const params = userDocumentParams();
  params.set('sort', 'username');
  return params;
}

function userGroupDocumentParams() {
  const params = new URLSearchParams();
  params.set('include', 'users');
  return params;
}

function userGroupListParams() {
  const params = userGroupDocumentParams();
  params.set('sort', 'name');
  return params;
}

function stringAttr(resource: JsonApiResource, name: string): string {
  const value = resource.attributes?.[name];
  return typeof value === 'string' ? value : '';
}

function optionalStringAttr(resource: JsonApiResource, name: string): string | null {
  const value = resource.attributes?.[name];
  return typeof value === 'string' && value !== '' ? value : null;
}

function booleanAttr(resource: JsonApiResource, name: string): boolean {
  return resource.attributes?.[name] === true;
}

function parseUserSummary(resource: JsonApiResource): AdminUserSummary | null {
  const id = toIntId(resource.id);
  if (!id) return null;

  return {
    id,
    username: stringAttr(resource, 'username'),
    is_admin: booleanAttr(resource, 'is_admin'),
  };
}

function parseGroupSummary(resource: JsonApiResource): AdminUserGroupSummary | null {
  const id = toIntId(resource.id);
  if (!id) return null;

  return {
    id,
    name: stringAttr(resource, 'name'),
  };
}

function parseAdminUser(resource: JsonApiResource, includedIndex = createJsonApiIncludedIndex()): AdminUser | null {
  const summary = parseUserSummary(resource);
  if (!summary) return null;

  const groups = relatedResources(resource, 'groups', includedIndex)
    .map(parseGroupSummary)
    .filter((group): group is AdminUserGroupSummary => Boolean(group))
    .sort((a, b) => a.name.localeCompare(b.name) || a.id - b.id);

  return {
    ...summary,
    created_at: optionalStringAttr(resource, 'created_at'),
    updated_at: optionalStringAttr(resource, 'updated_at'),
    groups,
  };
}

function parseAdminUserGroup(
  resource: JsonApiResource,
  includedIndex = createJsonApiIncludedIndex()
): AdminUserGroup | null {
  const summary = parseGroupSummary(resource);
  if (!summary) return null;

  const users = relatedResources(resource, 'users', includedIndex)
    .map(parseUserSummary)
    .filter((user): user is AdminUserSummary => Boolean(user))
    .sort((a, b) => a.username.localeCompare(b.username) || a.id - b.id);

  return {
    ...summary,
    created_at: optionalStringAttr(resource, 'created_at'),
    updated_at: optionalStringAttr(resource, 'updated_at'),
    users,
  };
}

function requireAdminUser(payload: JsonApiMutationResponse): AdminUser {
  const includedIndex = createJsonApiIncludedIndex(payload.included);
  const user = parseAdminUser(payload.data, includedIndex);
  if (!user) throw new Error('Invalid user response.');
  return user;
}

function requireAdminUserGroup(payload: JsonApiMutationResponse): AdminUserGroup {
  const includedIndex = createJsonApiIncludedIndex(payload.included);
  const group = parseAdminUserGroup(payload.data, includedIndex);
  if (!group) throw new Error('Invalid user group response.');
  return group;
}

function userAttributes(input: AdminUserInput) {
  return {
    username: input.username,
    is_admin: input.is_admin,
    groups: input.group_ids,
    ...(input.password !== undefined ? { password: input.password } : {}),
    ...(input.password_confirmation !== undefined
      ? { password_confirmation: input.password_confirmation }
      : {}),
  };
}

function userGroupAttributes(input: AdminUserGroupInput) {
  return {
    name: input.name,
    users: input.user_ids,
  };
}

export async function listAdminUsers(): Promise<AdminUser[]> {
  const payload = await jsonApiList(USERS_BASE_PATH, userListParams());
  const includedIndex = createJsonApiIncludedIndex(payload.included);

  return payload.data
    .map((resource) => parseAdminUser(resource, includedIndex))
    .filter((user): user is AdminUser => Boolean(user));
}

export async function getAdminUser(id: number): Promise<AdminUser> {
  const payload = await jsonApiGet(`${USERS_BASE_PATH}/${id}`, userDocumentParams());
  return requireAdminUser(payload);
}

export async function createAdminUser(input: AdminUserInput): Promise<AdminUser> {
  const payload = await jsonApiCreate(
    USERS_BASE_PATH,
    USER_TYPE,
    userAttributes(input),
    userDocumentParams()
  );

  return requireAdminUser(payload);
}

export async function updateAdminUser(id: number, input: AdminUserInput): Promise<AdminUser> {
  const payload = await jsonApiUpdate(
    USERS_BASE_PATH,
    USER_TYPE,
    id,
    userAttributes(input),
    userDocumentParams()
  );

  return requireAdminUser(payload);
}

export async function resetAdminUserPassword(
  id: number,
  input: Pick<AdminUserInput, 'password' | 'password_confirmation'>
): Promise<AdminUser> {
  const params = userDocumentParams();
  const qs = params.toString();
  const url = `${USERS_BASE_PATH}/${id}/reset-password${qs ? `?${qs}` : ''}`;

  const payload = await api.patch<JsonApiMutationResponse>(
    url,
    {
      data: {
        type: USER_TYPE,
        id: String(id),
        attributes: {
          password: input.password,
          password_confirmation: input.password_confirmation,
        },
      },
    },
    { headers: jsonApiHeaders() }
  );

  return requireAdminUser(payload);
}

export async function deleteAdminUser(id: number): Promise<void> {
  await jsonApiDelete(USERS_BASE_PATH, id);
}

export async function listAdminUserGroups(): Promise<AdminUserGroup[]> {
  const payload = await jsonApiList(USER_GROUPS_BASE_PATH, userGroupListParams());
  const includedIndex = createJsonApiIncludedIndex(payload.included);

  return payload.data
    .map((resource) => parseAdminUserGroup(resource, includedIndex))
    .filter((group): group is AdminUserGroup => Boolean(group));
}

export async function getAdminUserGroup(id: number): Promise<AdminUserGroup> {
  const payload = await jsonApiGet(`${USER_GROUPS_BASE_PATH}/${id}`, userGroupDocumentParams());
  return requireAdminUserGroup(payload);
}

export async function createAdminUserGroup(input: AdminUserGroupInput): Promise<AdminUserGroup> {
  const payload = await jsonApiCreate(
    USER_GROUPS_BASE_PATH,
    USER_GROUP_TYPE,
    userGroupAttributes(input),
    userGroupDocumentParams()
  );

  return requireAdminUserGroup(payload);
}

export async function updateAdminUserGroup(id: number, input: AdminUserGroupInput): Promise<AdminUserGroup> {
  const payload = await jsonApiUpdate(
    USER_GROUPS_BASE_PATH,
    USER_GROUP_TYPE,
    id,
    userGroupAttributes(input),
    userGroupDocumentParams()
  );

  return requireAdminUserGroup(payload);
}

export async function deleteAdminUserGroup(id: number): Promise<void> {
  await jsonApiDelete(USER_GROUPS_BASE_PATH, id);
}
