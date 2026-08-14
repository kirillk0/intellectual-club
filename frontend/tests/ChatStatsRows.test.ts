import { mount } from '@vue/test-utils';

import ChatStatsRows from '@/components/chat/ChatStatsRows.vue';
import { setPreferredLocale } from '@/i18n';
import { subtractIncludedTokens } from '@/utils/stepStats';

describe('ChatStatsRows token breakdowns', () => {
  beforeEach(() => {
    setPreferredLocale('en');
  });

  afterEach(() => {
    setPreferredLocale(null);
  });

  it('renders input and output totals with their included token categories', () => {
    const wrapper = mount(ChatStatsRows, {
      props: {
        stats: {
          input_tokens: 1_000,
          cached_input_tokens: 400,
          output_tokens: 250,
          reasoning_tokens: 100,
        },
      },
    });

    const groups = wrapper.findAll('.chat-stats-token-group');
    expect(groups).toHaveLength(2);
    expect(groups[0]!.findAll('.chat-stats-row').map((row) => row.text())).toEqual([
      'Input tokens (total)1,000',
      'Cold input tokens600',
      'Cached input tokens400',
    ]);
    expect(groups[1]!.findAll('.chat-stats-row').map((row) => row.text())).toEqual([
      'Output tokens (total, incl. reasoning)250',
      'Non-reasoning output tokens150',
      'Reasoning tokens100',
    ]);
  });

  it('leaves a calculated category unknown when the included count is unavailable', () => {
    const wrapper = mount(ChatStatsRows, {
      props: {
        stats: {
          input_tokens: 1_000,
          cached_input_tokens: null,
          output_tokens: 250,
          reasoning_tokens: null,
        },
      },
    });

    const parts = wrapper.findAll('.chat-stats-row--part').map((row) => row.text());
    expect(parts).toEqual([
      'Cold input tokens—',
      'Cached input tokens—',
      'Non-reasoning output tokens—',
      'Reasoning tokens—',
    ]);
  });

  it('localizes the breakdown labels', () => {
    setPreferredLocale('ru');
    const wrapper = mount(ChatStatsRows, {
      props: {
        stats: {
          input_tokens: 10,
          cached_input_tokens: 4,
          output_tokens: 8,
          reasoning_tokens: 3,
        },
      },
    });

    expect(wrapper.text()).toContain('Входные токены (всего)');
    expect(wrapper.text()).toContain('Некэшированные входные токены');
    expect(wrapper.text()).toContain('Выходные токены (всего, включая reasoning)');
    expect(wrapper.text()).toContain('Выходные токены без reasoning');
  });

  it('clamps inconsistent included counts instead of showing negative tokens', () => {
    expect(subtractIncludedTokens(10, 12)).toBe(0);
    expect(subtractIncludedTokens(10, null)).toBeNull();
  });
});
