import {
  jsonApiCreate,
  jsonApiDelete,
  jsonApiUpdate,
  type JsonApiMutationResponse,
} from '@/api/jsonApi';

const CHAT_BASE_PATH = '/api/ash/chats';
const CHAT_TYPE = 'chats';

type ChatAttributes = Record<string, unknown>;

function requireChatId(payload: JsonApiMutationResponse): number {
  const id = Number(payload.data?.id);
  if (!Number.isInteger(id) || id <= 0) throw new Error('Missing chat id');
  return id;
}

export async function createChatRecord(attributes: ChatAttributes = {}): Promise<number> {
  const payload = await jsonApiCreate(CHAT_BASE_PATH, CHAT_TYPE, attributes);
  return requireChatId(payload);
}

export async function copyChatRecord(sourceChatId: number): Promise<number> {
  const payload = await jsonApiCreate(`${CHAT_BASE_PATH}/${sourceChatId}/copy`, CHAT_TYPE, {});
  return requireChatId(payload);
}

export async function continueChatRecord(sourceChatId: number): Promise<number> {
  const payload = await jsonApiCreate(`${CHAT_BASE_PATH}/${sourceChatId}/continue`, CHAT_TYPE, {});
  return requireChatId(payload);
}

export async function updateChatRecord(chatId: number, attributes: ChatAttributes): Promise<void> {
  await jsonApiUpdate(CHAT_BASE_PATH, CHAT_TYPE, chatId, attributes);
}

export async function deleteChatRecord(chatId: number): Promise<void> {
  await jsonApiDelete(CHAT_BASE_PATH, chatId);
}
