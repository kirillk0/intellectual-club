import { computed, ref } from 'vue';
import { mount } from '@vue/test-utils';
import { useChatMessageActions } from '@/features/chat/model/useChatMessageActions';
import { useChatInspectors } from '@/features/chat/model/useChatInspectors';
import ChatMessageBubble from '@/components/chat/ChatMessageBubble.vue';
import ChatStepDetailsModal from '@/components/chat/ChatStepDetailsModal.vue';
import type { ChatBranchMessage } from '@/types/api';

const apiMocks = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn(), patch: vi.fn() }));
vi.mock('@/api/client', () => ({ api: apiMocks, getApiErrorMessage: (_e: unknown, fallback: string) => fallback }));

const message = (role: 'user' | 'assistant'): ChatBranchMessage => ({
  id: 10, role, status: 'error', prev_sibling_id: 9, next_sibling_id: 11,
  content: { items: [], parts: [{ content_id: 20, sequence: 1, text: 'local text', item_type: role === 'user' ? 'input' : 'answer' }], media: [] },
});

const actions = () => useChatMessageActions({
  chatId: computed(() => 1), chat: ref(null), readOnly: computed(() => false), historyReadOnly: computed(() => true),
  branch: ref([message('assistant')]), selectedConfig: ref(''),
  fileUploadPolicy: computed(() => ({ allowsFiles: true, imagesOnly: false, maxFileSizeBytes: 10000, accept: '*/*' })),
  waitForConfigSync: async () => true, messageConfigLabel: () => '', startPolling: async () => undefined,
  scrollToLastMessage: () => undefined, ensurePendingFilesUploaded: async () => [],
  removePendingFileFromCollection: async () => undefined, clearPendingFilesCollection: async () => undefined,
  pushChatRoute: () => undefined,
});

beforeEach(() => {
  Object.values(apiMocks).forEach((mock) => mock.mockReset());
  vi.spyOn(window, 'alert').mockImplementation(() => undefined);
});

it.each(['user', 'assistant'] as const)('guards all %s history action handlers while allowing local bookmarks', async (role) => {
  const vm = actions();
  const local = message(role);
  expect(vm.canDeleteMessage(local, 0)).toBe(false);
  vm.startEdit(local);
  vm.startBranch(local);
  vm.startBranchToNewChat(local);
  await vm.moveBranchToNewChat(local);
  await vm.confirmAndDeleteMessage(local, 0);
  await vm.retryLastStep(local);
  await vm.switchBranchHandler(10, 'prev');
  await vm.activateBranchHandler(10);
  expect(vm.editingMessage.value).toBeNull();
  expect(apiMocks.post).not.toHaveBeenCalled();
  expect(apiMocks.patch).not.toHaveBeenCalled();
  apiMocks.post.mockResolvedValue({ bookmarked: true });
  await vm.toggleBookmark(local);
  expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-messages/10/bookmark', {});
  await vm.dispose();
});

it.each(['user', 'assistant'] as const)('hides %s history mutation affordances without hiding inspection', async (role) => {
  const wrapper = mount(ChatMessageBubble, { props: { message: message(role), index: 0, historyReadonly: true }, global: { stubs: { Teleport: true } } });
  expect(wrapper.find('.retry-link').exists()).toBe(false);
  expect(wrapper.find('button[title="Branch"]').exists()).toBe(false);
  expect(wrapper.find('[aria-label="Previous branch"]').exists()).toBe(false);
  const more = wrapper.find('button[title="More actions"]');
  if (more.exists()) await more.trigger('click');
  expect(wrapper.find('[aria-label="Edit message 1"]').exists()).toBe(false);
  expect(wrapper.find('[aria-label="Branch message 1 to new chat"]').exists()).toBe(false);
  expect(wrapper.text()).toContain('local text');
  expect(wrapper.find('[role="menuitemcheckbox"]').exists()).toBe(true);
  wrapper.unmount();
});

it('blocks step retry in the inspector handler and hides the modal retry button', async () => {
  const vm = useChatInspectors({
    historyReadOnly: ref(true), compiledPromptText: ref(''), loadError: ref(''), replaceBranch: vi.fn(),
    branchMessageById: () => message('assistant'), retryConfigurationWarning: () => '', startPolling: vi.fn(),
    scrollToLastMessage: vi.fn(), composerPendingFiles: ref([]), editPendingFiles: ref([]), editExistingAttachments: ref([]),
  });
  vm.stepDetailsMessageId.value = 10;
  vm.stepDetailsStep.value = { id: 40, sequence: 1, status: 'done' };
  await vm.retryFromStep();
  expect(apiMocks.post).not.toHaveBeenCalled();
  const wrapper = mount(ChatStepDetailsModal, {
    props: { open: true, messageId: 10, messageStatus: 'done', step: { id: 40, sequence: 1, status: 'done' }, historyReadonly: true },
    global: { stubs: { Teleport: true } },
  });
  expect(wrapper.find('.step-actions-link').exists()).toBe(false);
  wrapper.unmount();
});
