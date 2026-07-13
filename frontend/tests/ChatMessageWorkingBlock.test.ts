import { mount } from '@vue/test-utils';

import ChatMessageWorkingBlock from '@/components/chat/ChatMessageWorkingBlock.vue';
import { setPreferredLocale } from '@/i18n';
import type { ChatMessageContent, ChatMessageItem, ChatMessageStep } from '@/types/api';

const textContent = (id: number, text: string): ChatMessageContent => ({
  id,
  sequence: 1,
  kind: 'text',
  content_text: text,
});

const traceItem = (id: number, sequence: number, type: string, text: string): ChatMessageItem => ({
  id,
  sequence,
  type,
  contents: [textContent(id * 10, text)],
});

describe('ChatMessageWorkingBlock canonical trace', () => {
  beforeEach(() => {
    setPreferredLocale('en');
  });

  afterEach(() => {
    setPreferredLocale(null);
  });

  it('renders answer and steering previews in item sequence with a 50-character limit', () => {
    const longAnswer = '1234567890'.repeat(6);
    const step: ChatMessageStep = {
      id: 20,
      sequence: 1,
      status: 'done',
      response_final: true,
      items: [
        traceItem(4, 4, 'answer', longAnswer),
        traceItem(2, 2, 'steering', 'Please\nchange   direction'),
        traceItem(1, 1, 'reasoning', 'First thought'),
        traceItem(3, 3, 'tool_result', 'Tool output'),
      ],
    };

    const wrapper = mount(ChatMessageWorkingBlock, {
      props: {
        messageId: 10,
        messageStatus: 'done',
        summary: { step_count: 1, completed_step_duration_ms: 0 },
        stepIndex: [step],
        selectedStep: step,
        open: true,
      },
      global: {
        stubs: {
          ChatMediaList: true,
          JsonTreeView: true,
          SvgIcon: true,
        },
      },
    });

    const items = wrapper.findAll('.working-item');
    expect(items).toHaveLength(4);
    expect(items[0]?.text()).toContain('First thought');
    expect(items[1]?.get('.working-item-preview-label').text()).toBe('Steering:');
    expect(items[1]?.get('.working-item-preview-text').text()).toBe('Please change direction');
    expect(items[2]?.text()).toContain('Tool output');
    expect(items[3]?.get('.working-item-preview-label').text()).toBe('Answering:');
    expect(items[3]?.get('.working-item-preview-text').text()).toBe(`${'1234567890'.repeat(5)}…`);
    expect(wrapper.text()).not.toContain(longAnswer);
  });

  it('localizes compact trace labels', () => {
    setPreferredLocale('ru');
    const step: ChatMessageStep = {
      id: 20,
      sequence: 1,
      items: [
        traceItem(1, 1, 'answer', 'Ответ'),
        traceItem(2, 2, 'steering', 'Уточнение'),
      ],
    };

    const wrapper = mount(ChatMessageWorkingBlock, {
      props: {
        messageId: 10,
        messageStatus: 'done',
        summary: { step_count: 1, completed_step_duration_ms: 0 },
        stepIndex: [step],
        selectedStep: step,
        open: true,
      },
    });

    const labels = wrapper.findAll('.working-item-preview-label').map((label) => label.text());
    expect(labels).toEqual(['Отвечает:', 'Направление:']);
  });

  it('renders tool call arguments with the collapsible JSON viewer', () => {
    const longValue = 'x'.repeat(200);
    const toolCall: ChatMessageItem = {
      id: 7,
      sequence: 1,
      type: 'tool_call',
      contents: [
        {
          id: 70,
          sequence: 1,
          kind: 'opaque',
          content_json: {
            name: 'reader__read_url',
            arguments: JSON.stringify({ request: { url: longValue } }),
          },
        },
      ],
    };
    const step: ChatMessageStep = {
      id: 20,
      sequence: 1,
      status: 'done',
      items: [toolCall],
    };

    const wrapper = mount(ChatMessageWorkingBlock, {
      props: {
        messageId: 10,
        messageStatus: 'done',
        summary: { step_count: 1, completed_step_duration_ms: 0 },
        stepIndex: [step],
        selectedStep: step,
        open: true,
      },
      global: {
        stubs: {
          ChatMediaList: true,
          JsonTreeView: {
            name: 'JsonTreeView',
            props: {
              value: { default: null },
              downloadFilename: String,
              preserveExpandedOnValueChange: Boolean,
            },
            template: '<div class="json-tree-view-stub" />',
          },
          SvgIcon: true,
        },
      },
    });

    const viewer = wrapper.getComponent({ name: 'JsonTreeView' });
    expect(viewer.props('value')).toEqual({ request: { url: longValue } });
    expect(viewer.props('downloadFilename')).toBe('tool-call-7-arguments.json');
    expect(viewer.props('preserveExpandedOnValueChange')).toBe(true);
    expect(wrapper.find('.working-json-block').exists()).toBe(false);
  });
});
