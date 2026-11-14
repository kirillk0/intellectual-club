import { computed, ref } from 'vue';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  post: vi.fn(),
  patch: vi.fn(),
}));

vi.mock('@/api/client', () => ({
  api: apiMocks,
  getApiErrorMessage: (error: unknown, fallback: string) =>
    error instanceof Error && error.message ? error.message : fallback,
}));

const publishChatChange = vi.hoisted(() => vi.fn());

vi.mock('@/features/chat/chatEvents', () => ({ publishChatChange }));

import {
  createPendingChatFiles,
  initialPendingImageState,
  type ChatUploadPolicy,
  type PendingChatFile,
} from '@/features/chat/attachments';
import { useChatMessageActions } from '@/features/chat/model/useChatMessageActions';
import type { Chat, ChatBranchMessage } from '@/types/api';

const noFiles: ChatUploadPolicy = { allowsFiles: false, imagesOnly: false, maxFileSizeBytes: 10_000, accept: '' };
const imagesOnly: ChatUploadPolicy = {
  allowsFiles: true,
  imagesOnly: true,
  maxFileSizeBytes: 10_000,
  accept: 'image/*',
};
const anyFiles: ChatUploadPolicy = { allowsFiles: true, imagesOnly: false, maxFileSizeBytes: 10_000, accept: '' };

const userMessage: ChatBranchMessage = {
  id: 10,
  role: 'user',
  status: 'done',
  parent_id: null,
  content: {
    items: [],
    parts: [
      {
        content_id: 1,
        sequence: 0,
        text: 'Question',
        item_type: 'user',
        step_sequence: 1,
        item_sequence: 1,
      },
    ],
    media: [],
  },
};

const assistantMessage: ChatBranchMessage = {
  id: 11,
  role: 'assistant',
  status: 'done',
  parent_id: 10,
  llm_configuration_id: 7,
  content: { items: [], parts: [], media: [] },
};

const createActions = (
  overrides: {
    selectedConfig?: number | '';
    chatUploadPolicy?: ChatUploadPolicy;
    uploadPolicyForConfig?: (configId: number) => ChatUploadPolicy;
    messageConfigLabel?: (configId?: number | null, snapshot?: string | null) => string;
    addPendingFilesToCollection?: Parameters<typeof useChatMessageActions>[0]['addPendingFilesToCollection'];
  } = {}
) => {
  const branch = ref<ChatBranchMessage[]>([userMessage, assistantMessage]);
  const chatId = ref(1);
  const waitForConfigSync = vi.fn(async () => true);
  const startPolling = vi.fn(async () => undefined);
  const scrollToLastMessage = vi.fn();
  const pushChatRoute = vi.fn();
  const applyServerConfiguration = vi.fn();
  const ensurePendingFilesUploaded = vi.fn(async () => ['upload-1']);
  const actions = useChatMessageActions({
    chatId: computed(() => chatId.value),
    chat: ref({ id: 1, llm_configuration_id: 7 } as Chat),
    readOnly: computed(() => false),
    branch,
    selectedConfig: ref(overrides.selectedConfig ?? 7),
    fileUploadPolicy: computed(() => overrides.chatUploadPolicy ?? anyFiles),
    uploadPolicyForConfig: overrides.uploadPolicyForConfig,
    waitForConfigSync,
    messageConfigLabel: overrides.messageConfigLabel ?? (() => ''),
    startPolling,
    scrollToLastMessage,
    ensurePendingFilesUploaded,
    addPendingFilesToCollection: overrides.addPendingFilesToCollection,
    removePendingFileFromCollection: async () => undefined,
    clearPendingFilesCollection: async () => undefined,
    pushChatRoute,
    applyServerConfiguration,
  });

  return {
    actions,
    chatId,
    waitForConfigSync,
    branch,
    startPolling,
    scrollToLastMessage,
    pushChatRoute,
    applyServerConfiguration,
    ensurePendingFilesUploaded,
  };
};

describe('chat message branch options', () => {
  beforeEach(() => {
    apiMocks.post.mockReset();
    publishChatChange.mockReset();
  });

  it('uses the configuration snapshot in the retry warning without changing its selection', () => {
    const messageConfigLabel = vi.fn((id?: number | null, snapshot?: string | null) => snapshot || `Config #${id}`);
    const { actions } = createActions({ selectedConfig: 9, messageConfigLabel });
    const message = { ...assistantMessage, llm_configuration_label_snapshot: 'Original Model' };

    expect(actions.retryConfigurationWarning(message)).toContain('(Original Model)');
    expect(actions.retryConfigurationWarning(message)).toContain('(Config #9)');
    expect(messageConfigLabel).toHaveBeenCalledWith(7, 'Original Model');
    expect(actions.retryConfigurationWarning({ ...message, llm_configuration_id: null })).toBe('');
  });

  it('branches an assistant response in place immediately without branch options', async () => {
    const { actions, branch, startPolling } = createActions();
    const nextBranch = [userMessage, { ...assistantMessage, id: 12, status: 'generating' as const }];
    apiMocks.post.mockResolvedValue({ branch: nextBranch, generation: { message_id: 12 } });

    actions.startBranch(assistantMessage);
    await vi.waitFor(() => expect(startPolling).toHaveBeenCalledWith(12));

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-generation/1/generate', { parent_id: 10 });
    expect(branch.value).toEqual(nextBranch);
    expect(actions.editingMessage.value).toBeNull();
  });

  it('branches a generating assistant with the newly selected model after configuration sync', async () => {
    const { actions, branch, startPolling, waitForConfigSync } = createActions({ selectedConfig: 9 });
    branch.value = [userMessage, { ...assistantMessage, status: 'generating' }];
    let resolve!: (value: boolean) => void;
    waitForConfigSync.mockReturnValue(new Promise((done) => { resolve = done; }));
    const nextBranch = [userMessage, { ...assistantMessage, id: 12, status: 'generating', llm_configuration_id: 9 }];
    apiMocks.post.mockResolvedValue({ branch: nextBranch, generation: { message_id: 12 } });

    actions.startBranch(branch.value[1]!);
    expect(apiMocks.post).not.toHaveBeenCalled();
    resolve(true);
    await vi.waitFor(() => expect(startPolling).toHaveBeenCalledWith(12));
    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-generation/1/generate', { parent_id: 10 });
    expect(branch.value).toEqual(nextBranch);
    expect(actions.editingMessage.value).toBeNull();
  });

  it('retries an earlier response while another response is generating', async () => {
    const { actions, branch, startPolling } = createActions();
    branch.value = [...branch.value, { ...assistantMessage, id: 12, status: 'generating' }];
    const nextBranch = [userMessage, { ...assistantMessage, id: 13, status: 'generating' }];
    apiMocks.post.mockResolvedValue({ branch: nextBranch, generation: { message_id: 13 } });

    await actions.retryLastStep(assistantMessage);
    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-messages/11/retry-last-step', {});
    expect(startPolling).toHaveBeenCalledWith(13);
    expect(branch.value).toEqual(nextBranch);
  });

  it.each([
    ['assistant', false], ['user', false], ['retry', false],
    ['assistant', true], ['user', true], ['retry', true],
  ] as const)('ignores late %s branch starts after navigation (new chat: %s)', async (action, changeChat) => {
    const { actions, branch, chatId, startPolling, applyServerConfiguration } = createActions();
    let resolve!: (value: unknown) => void;
    apiMocks.post.mockReturnValue(new Promise((done) => { resolve = done; }));
    let pending: Promise<void> | undefined;
    if (action === 'assistant') actions.startBranch(assistantMessage);
    else if (action === 'retry') pending = actions.retryLastStep(assistantMessage);
    else {
      actions.startBranch(userMessage);
      pending = actions.saveEdit();
    }
    await vi.waitFor(() => expect(apiMocks.post).toHaveBeenCalledTimes(1));
    if (changeChat) chatId.value = 2;
    branch.value = [{ ...assistantMessage, id: 99 }];
    resolve({
      branch: [userMessage, { ...assistantMessage, id: 12, status: 'generating' }],
      chat: { llm_configuration_id: 9 },
      generation: { message_id: 12 },
    });
    await pending;
    await Promise.resolve();
    expect(branch.value.map((message) => message.id)).toEqual([99]);
    expect(startPolling).not.toHaveBeenCalled();
    expect(applyServerConfiguration).not.toHaveBeenCalled();
  });

  it.each([
    ['assistant', 'config'], ['user', 'config'], ['user', 'upload'],
    ['assistant', 'post'], ['user', 'post'], ['retry', 'post'],
  ] as const)('accepts %s branch starts after a same-branch reload during %s', async (action, stage) => {
    const { actions, branch, waitForConfigSync, ensurePendingFilesUploaded, startPolling } = createActions();
    let resolveConfig!: (value: boolean) => void;
    let resolveUpload!: (value: string[]) => void;
    let resolvePost!: (value: unknown) => void;
    waitForConfigSync.mockReturnValue(new Promise((resolve) => { resolveConfig = resolve; }));
    ensurePendingFilesUploaded.mockReturnValue(new Promise((resolve) => { resolveUpload = resolve; }));
    apiMocks.post.mockReturnValue(new Promise((resolve) => { resolvePost = resolve; }));
    let pending: Promise<void> | undefined;
    if (action === 'assistant') actions.startBranch(assistantMessage);
    else if (action === 'retry') pending = actions.retryLastStep(assistantMessage);
    else {
      actions.startBranch(userMessage);
      if (stage === 'upload') actions.addEditPendingFiles([new File(['file'], 'note.txt', { type: 'text/plain' })]);
      pending = actions.saveEdit();
    }
    if (stage !== 'config') {
      resolveConfig(true);
      if (stage === 'upload') await vi.waitFor(() => expect(ensurePendingFilesUploaded).toHaveBeenCalledTimes(1));
      else await vi.waitFor(() => expect(apiMocks.post).toHaveBeenCalledTimes(1));
    }
    branch.value = branch.value.map((message) => ({ ...message, token_count: 100 }));
    resolveConfig(true);
    resolveUpload(['upload-1']);
    const nextBranch = [userMessage, { ...assistantMessage, id: 12, status: 'generating' }];
    resolvePost({ branch: nextBranch, generation: { message_id: 12 } });
    await pending;
    await vi.waitFor(() => expect(startPolling).toHaveBeenCalledWith(12));
    expect(branch.value).toEqual(nextBranch);
    expect(apiMocks.post).toHaveBeenCalledTimes(1);
    if (stage === 'upload') expect(apiMocks.post).toHaveBeenCalledWith(
      '/api/bff/chat-generation/1/branch', expect.objectContaining({ upload_ids: ['upload-1'] })
    );
  });

  it.each([false, true])('keeps polling ownership after applying branch configuration (navigation: %s)', async (navigate) => {
    const { actions, branch, applyServerConfiguration, startPolling } = createActions();
    let resolveConfig!: () => void;
    applyServerConfiguration.mockReturnValue(new Promise<void>((resolve) => { resolveConfig = resolve; }));
    apiMocks.post.mockResolvedValue({
      branch: [userMessage, { ...assistantMessage, id: 12, status: 'generating' }],
      chat: { llm_configuration_id: 9 }, generation: { message_id: 12 },
    });
    actions.startBranch(userMessage);
    const pending = actions.saveEdit();
    await vi.waitFor(() => expect(applyServerConfiguration).toHaveBeenCalledWith(9));
    branch.value = branch.value.map((message) => ({ ...message, id: navigate ? message.id + 100 : message.id }));
    resolveConfig();
    await pending;
    if (navigate) expect(startPolling).not.toHaveBeenCalled();
    else expect(startPolling).toHaveBeenCalledWith(12);
  });

  it.each([
    ['user', true], ['user', false], ['assistant', true], ['retry', true],
  ] as const)('completes %s branching when a server refresh arrives before the response (generation: %s)', async (action, generate) => {
    const { actions, branch, startPolling, applyServerConfiguration } = createActions();
    let resolve!: (value: unknown) => void;
    apiMocks.post.mockReturnValue(new Promise((done) => { resolve = done; }));
    let pending: Promise<void> | undefined;
    if (action === 'assistant') actions.startBranch(assistantMessage);
    else if (action === 'retry') pending = actions.retryLastStep(assistantMessage);
    else {
      actions.startBranch(userMessage);
      actions.editContents.value = ['Edited question'];
      actions.branchStartGeneration.value = generate;
      pending = actions.saveEdit();
    }
    await vi.waitFor(() => expect(apiMocks.post).toHaveBeenCalledTimes(1));

    const nextUser = action === 'user' ? { ...userMessage, id: 20 } : userMessage;
    const nextBranch = generate
      ? [nextUser, { ...assistantMessage, id: 21, parent_id: nextUser.id, status: 'generating' }]
      : [nextUser];
    branch.value = nextBranch.map((message) => ({ ...message }));
    resolve({ branch: nextBranch, chat: { llm_configuration_id: 7 }, generation: generate ? { message_id: 21 } : null });
    await pending;
    await vi.waitFor(() => {
      expect(actions.savingEdit.value).toBe(false);
      expect(actions.branchingAssistantId.value).toBeNull();
      expect(actions.retryingMessageId.value).toBeNull();
    });

    expect(actions.editingMessage.value).toBeNull();
    if (generate) expect(startPolling).toHaveBeenCalledWith(21);
    else expect(startPolling).not.toHaveBeenCalled();
    if (action === 'user') {
      expect(applyServerConfiguration).toHaveBeenCalledWith(7);
      await actions.saveEdit();
    }
    expect(apiMocks.post).toHaveBeenCalledTimes(1);
  });

  it.each([false, true])('only accepts a refreshed ancestor if it belongs to the newly created branch (new: %s)', async (created) => {
    const { actions, branch, startPolling } = createActions();
    const ancestor = { ...assistantMessage, id: 5, parent_id: null };
    const source = { ...userMessage, parent_id: ancestor.id };
    branch.value = [ancestor, source, assistantMessage];
    let resolve!: (value: unknown) => void;
    apiMocks.post.mockReturnValue(new Promise((done) => { resolve = done; }));
    actions.startBranch(source);
    const pending = actions.saveEdit();
    await vi.waitFor(() => expect(apiMocks.post).toHaveBeenCalledTimes(1));

    const nextUser = { ...source, id: 20 };
    branch.value = created ? [ancestor, nextUser] : [ancestor];
    const nextBranch = [ancestor, nextUser, { ...assistantMessage, id: 21, parent_id: 20 }];
    resolve({ branch: nextBranch, generation: { message_id: 21 } });
    await pending;

    if (created) {
      expect(branch.value).toEqual(nextBranch);
      expect(actions.editingMessage.value).toBeNull();
      expect(startPolling).toHaveBeenCalledWith(21);
    } else {
      expect(branch.value).toEqual([ancestor]);
      expect(startPolling).not.toHaveBeenCalled();
    }
  });

  it('branches an assistant response to a new chat immediately without branch options', async () => {
    const { actions, pushChatRoute } = createActions();
    apiMocks.post.mockResolvedValue({ chat: { id: 42 }, generation: { message_id: 50 } });

    actions.startBranchToNewChat(assistantMessage);
    await vi.waitFor(() => expect(pushChatRoute).toHaveBeenCalledWith(42));

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-generation/1/branch-to-new-chat', {
      message_id: 11,
    });
    expect(actions.editingMessage.value).toBeNull();
  });

  it('resets user branch dialog options to the selected configuration with generation enabled', () => {
    const { actions } = createActions({ selectedConfig: 9 });
    actions.branchStartGeneration.value = false;
    actions.branchConfigId.value = 3;

    actions.startBranchToNewChat(userMessage);

    expect(actions.modalMode.value).toBe('branch_new_chat');
    expect(actions.branchConfigId.value).toBe(9);
    expect(actions.branchStartGeneration.value).toBe(true);
  });

  it('sends edited user branches in place with the dialog options', async () => {
    const { actions, startPolling, applyServerConfiguration } = createActions();
    apiMocks.post.mockResolvedValue({
      branch: [{ ...userMessage, id: 20 }],
      chat: { id: 1, llm_configuration_id: 8 },
      generation: null,
    });

    actions.startBranch(userMessage);
    expect(actions.modalMode.value).toBe('branch');
    expect(actions.branchConfigId.value).toBe(7);
    actions.editContents.value = ['Edited question'];
    actions.branchConfigId.value = 8;
    actions.branchStartGeneration.value = false;
    await actions.saveEdit();

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-generation/1/branch', {
      message_id: 10,
      content: 'Edited question',
      start_generation: false,
      llm_configuration_id: 8,
    });
    expect(applyServerConfiguration).toHaveBeenCalledWith(8);
    expect(startPolling).not.toHaveBeenCalled();
    expect(actions.editingMessage.value).toBeNull();
  });

  it('sends edited user branches to a new chat with the dialog options', async () => {
    const { actions, pushChatRoute } = createActions();
    apiMocks.post.mockResolvedValue({ chat: { id: 43 }, generation: { message_id: 50 } });

    actions.startBranchToNewChat(userMessage);
    actions.editContents.value = ['Edited question'];
    actions.branchConfigId.value = 8;
    await actions.saveEdit();

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-generation/1/branch-to-new-chat', {
      message_id: 10,
      content: 'Edited question',
      start_generation: true,
      llm_configuration_id: 8,
    });
    expect(pushChatRoute).toHaveBeenCalledWith(43);
  });

  it('edits assistant output without changing checkpoint text or archives', () => {
    const { actions } = createActions();
    const media = (id: number, item_type: string) => ({
      id, item_type, sequence: 1, kind: 'media',
      media: {
        external_id: `content-${id}`, file_external_id: `file-${id}`,
        filename: `${id}.md`, mime_type: 'text/markdown', size_bytes: 10,
        sha256: 'digest', is_image: false,
      },
    });
    actions.startEdit({
      ...assistantMessage,
      content: {
        items: [],
        parts: [
          { content_id: 1, sequence: 1, text: 'Answer', item_type: 'answer', step_sequence: 1 },
          { content_id: 2, sequence: 1, text: 'History', item_type: 'handoff_history', step_sequence: 2 },
          { content_id: 3, sequence: 1, text: 'Summary', item_type: 'handoff_message', step_sequence: 2 },
          { content_id: 4, sequence: 1, text: 'Final answer', item_type: 'answer', step_sequence: 3 },
        ],
        media: [media(5, 'handoff_history'), media(6, 'artifact')],
      },
    });
    expect(actions.editContents.value).toEqual(['Answer', 'Final answer']);
    expect(actions.editExistingAttachments.value).toHaveLength(1);
    expect(actions.editExistingAttachments.value[0]?.name).toBe('6.md');
  });

  describe('branch dialog attachments', () => {
    const image = () => new File(['png'], 'pic.png', { type: 'image/png' });
    // The chat configuration (7) accepts no files; configuration 8 accepts images.
    const policyForConfig = (configId: number) => (configId === 8 ? imagesOnly : noFiles);

    it('follows the configuration selected in the branch dialog', () => {
      const { actions } = createActions({ chatUploadPolicy: noFiles, uploadPolicyForConfig: policyForConfig });

      actions.startBranchToNewChat(userMessage);
      expect(actions.editAttachmentsEnabled.value).toBe(false);
      actions.addEditPendingFiles([image()]);
      expect(actions.editPendingFiles.value).toHaveLength(0);
      expect(actions.editErrorText.value).toBe('File uploads are disabled for the current bot and configuration.');

      actions.branchConfigId.value = 8;
      expect(actions.editAttachmentsEnabled.value).toBe(true);
      expect(actions.editAttachmentAccept.value).toBe('image/*');
      expect(actions.editAttachmentHelp.value).toContain('Only image files');
      actions.addEditPendingFiles([image()]);
      expect(actions.editPendingFiles.value).toHaveLength(1);
      expect(actions.editErrorText.value).toBe('');
    });

    it('adds files through the preparing runtime and checks the variant each one uploads', () => {
      const addPendingFilesToCollection = vi.fn();
      const { actions } = createActions({
        chatUploadPolicy: noFiles,
        uploadPolicyForConfig: policyForConfig,
        addPendingFilesToCollection,
      });
      const sizeError = 'File "big.png" exceeds the maximum size of 9.8 KB.';

      actions.startBranchToNewChat(userMessage);
      actions.branchConfigId.value = 8;
      const picked = [image()];
      actions.addEditPendingFiles(picked);
      expect(addPendingFilesToCollection).toHaveBeenCalledWith(actions.editPendingFiles, picked, imagesOnly, expect.any(Function));
      const setError = addPendingFilesToCollection.mock.calls[0][3] as (error: string) => void;
      setError(sizeError);
      expect(actions.editErrorText.value).toBe(sizeError);
      setError('');

      // An image over the limit is fine while its compressed copy is prepared, not once the original is what remains.
      const big = new File([new Uint8Array(20_000)], 'big.png', { type: 'image/png' });
      const processing: PendingChatFile = {
        ...createPendingChatFiles([big])[0],
        image: { ...initialPendingImageState(big, imagesOnly.maxFileSizeBytes), phase: 'processing' },
      };
      actions.editPendingFiles.value = [processing];
      expect(actions.editAttachmentPolicyError.value).toBe('');
      actions.editPendingFiles.value = [{ ...processing, image: { ...processing.image!, phase: 'ready', failed: true } }];
      expect(actions.editAttachmentPolicyError.value).toBe(sizeError);
    });

    it('keeps the chat policy for in-place edits', () => {
      const { actions } = createActions({ chatUploadPolicy: noFiles, uploadPolicyForConfig: () => anyFiles });

      actions.startEdit(userMessage);
      actions.branchConfigId.value = 8;

      expect(actions.editAttachmentsEnabled.value).toBe(false);
    });

    it('blocks saving files the newly selected configuration does not allow', async () => {
      const { actions, ensurePendingFilesUploaded } = createActions({
        chatUploadPolicy: noFiles,
        uploadPolicyForConfig: policyForConfig,
      });
      apiMocks.post.mockResolvedValue({ chat: { id: 44 }, generation: null });

      actions.startBranchToNewChat(userMessage);
      actions.branchConfigId.value = 8;
      actions.addEditPendingFiles([image()]);
      actions.branchConfigId.value = 7;

      expect(actions.editAttachmentPolicyError.value).toBe(
        'File uploads are disabled for the current bot and configuration.'
      );
      await actions.saveEdit();
      expect(apiMocks.post).not.toHaveBeenCalled();
      expect(ensurePendingFilesUploaded).not.toHaveBeenCalled();

      actions.branchConfigId.value = 8;
      await actions.saveEdit();

      expect(ensurePendingFilesUploaded).toHaveBeenCalledWith(actions.editPendingFiles, undefined, {
        llmConfigurationId: 8,
      });
      expect(apiMocks.post).toHaveBeenCalledWith(
        '/api/bff/chat-generation/1/branch-to-new-chat',
        expect.objectContaining({ upload_ids: ['upload-1'], llm_configuration_id: 8 })
      );
    });
  });
});
