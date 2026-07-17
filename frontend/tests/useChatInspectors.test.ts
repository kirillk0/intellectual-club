import { flushPromises } from '@vue/test-utils';
import { ref } from 'vue';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
}));

vi.mock('@/api/client', () => ({
  api: apiMocks,
  getApiErrorMessage: (_error: unknown, fallback: string) => fallback,
}));

import { useChatInspectors } from '@/features/chat/model/useChatInspectors';

const createInspectors = () =>
  useChatInspectors({
    compiledPromptText: ref(''),
    loadError: ref(''),
    replaceBranch: vi.fn(),
    branchMessageById: vi.fn().mockReturnValue(null),
    retryConfigurationWarning: vi.fn().mockReturnValue(''),
    startPolling: vi.fn().mockResolvedValue(undefined),
    scrollToLastMessage: vi.fn(),
    composerPendingFiles: ref([]),
    editPendingFiles: ref([]),
    editExistingAttachments: ref([]),
  });

describe('chat step details', () => {
  beforeEach(() => {
    apiMocks.get.mockReset().mockImplementation((url: string) => {
      if (url.endsWith('kind=response')) {
        return Promise.resolve({
          step: {
            raw_response: {
              status_code: 429,
              body: { error: { message: 'Provider returned error' } },
            },
          },
        });
      }

      return Promise.resolve({ step: { raw_request: { model: 'test-model' } } });
    });
  });

  it('loads the raw response for a completed retry while the message is still generating', async () => {
    const inspectors = createInspectors();

    inspectors.openStepDetails({
      messageId: 42,
      messageStatus: 'generating',
      step: {
        id: 7,
        sequence: 2,
        status: 'error',
        response_final: false,
      },
    });
    await flushPromises();

    expect(inspectors.stepDetailsShowResponse.value).toBe(true);
    expect(inspectors.stepDetailsResponsePayload.value).toEqual({
      status_code: 429,
      body: { error: { message: 'Provider returned error' } },
    });
    expect(apiMocks.get).toHaveBeenCalledWith(
      '/api/bff/chat-messages/42/steps/7/raw?kind=response'
    );
  });
});
