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
  it('renders file downloads and inline images in working steps', () => {
    const fileId = 'c6012361-90b8-4f6b-afb0-35729ae584c6';
    const step: ChatMessageStep = {
      id: 20,
      sequence: 1,
      status: 'done',
      items: [traceItem(1, 1, 'reasoning', `[File](file://${fileId})\n\n![Image](file://${fileId})`)],
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

    expect(wrapper.get('.working-item-body a').attributes('href')).toBe(`/api/bff/chat-files/${fileId}`);
    expect(wrapper.get('.working-item-body a').attributes()).toHaveProperty('download');
    expect(wrapper.get('.working-item-body img').attributes('src')).toBe(`/api/bff/chat-files/${fileId}?inline=1`);
    wrapper.unmount();
  });

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
    expect(items[1]?.get('.working-item-preview-label').text()).toBe('Steering');
    expect(items[1]?.get('.working-item-preview-text').text()).toBe('Please change direction');
    expect(items[2]?.text()).toContain('Tool output');
    expect(items[3]?.get('.working-item-preview-label').text()).toBe('Answering');
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
    expect(labels).toEqual(['Отвечает', 'Направление']);
    expect(wrapper.get('.working-step-label').text()).toBe('Шаг 1');
  });

  it('renders each tool result and its artifacts right after the matching call', () => {
    const toolCall = (id: number, sequence: number, name: string): ChatMessageItem => ({
      id,
      sequence,
      type: 'tool_call',
      contents: [{ id: id * 10, sequence: 1, kind: 'opaque', content_json: { name, arguments: '{}' } }],
    });
    const toolResult = (id: number, sequence: number, callId: number, text: string): ChatMessageItem => ({
      ...traceItem(id, sequence, 'tool_result', text),
      tool_call_item_id: callId,
    });
    const step: ChatMessageStep = {
      id: 20,
      sequence: 1,
      status: 'done',
      items: [
        traceItem(1, 1, 'reasoning', 'Plan'),
        toolCall(2, 2, 'web__search'),
        toolCall(3, 3, 'web__read'),
        toolCall(4, 4, 'web__fetch'),
        toolResult(5, 1_003_000, 3, 'Read output'),
        toolResult(6, 1_002_000, 2, 'Search output'),
        traceItem(7, 1_002_001, 'artifact', ''),
        traceItem(8, 1_005_000, 'tool_result', 'Orphan output'),
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
      global: { stubs: { ChatMediaList: true, JsonTreeView: true, SvgIcon: true } },
    });

    const items = wrapper.findAll('.working-trace > .working-item');
    expect(items).toHaveLength(5);
    expect(items[0]?.text()).toContain('Plan');

    expect(items[1]?.get('.working-tool-name').text()).toBe('web__search');
    expect(items[1]?.get('.working-tool-result').text()).toBe('Search output');
    expect(items[1]?.findAll('.working-item-section .working-section-label').map((label) => label.text())).toEqual([
      'Result',
      'Artifact',
    ]);

    expect(items[2]?.get('.working-tool-name').text()).toBe('web__read');
    expect(items[2]?.get('.working-tool-result').text()).toBe('Read output');

    expect(items[3]?.get('.working-tool-name').text()).toBe('web__fetch');
    expect(items[3]?.find('.working-tool-result').exists()).toBe(false);
    expect(items[3]?.get('.working-item-status').text()).toBe('No result');

    expect(items[4]?.get('.working-item-label').text()).toBe('Tool result');
    expect(items[4]?.get('.working-tool-result').text()).toBe('Orphan output');
  });

  it('marks tool calls of the active step without results as running', () => {
    const step: ChatMessageStep = {
      id: 20,
      sequence: 1,
      status: 'waiting_tools',
      created_at: new Date().toISOString(),
      items: [
        {
          id: 2,
          sequence: 2,
          type: 'tool_call',
          contents: [{ id: 20, sequence: 1, kind: 'opaque', content_json: { name: 'shell__run', arguments: '{}' } }],
        },
      ],
    };

    const wrapper = mount(ChatMessageWorkingBlock, {
      props: {
        messageId: 10,
        messageStatus: 'generating',
        summary: { step_count: 1, completed_step_duration_ms: 0 },
        stepIndex: [step],
        selectedStep: step,
        open: true,
      },
      global: { stubs: { ChatMediaList: true, JsonTreeView: true, SvgIcon: true } },
    });

    const item = wrapper.get('.working-item--tool');
    expect(item.classes()).toContain('working-item--pending');
    expect(item.get('.working-item-status').text()).toBe('Running…');
    wrapper.unmount();
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
