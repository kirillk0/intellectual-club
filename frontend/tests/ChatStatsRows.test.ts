import { mount } from '@vue/test-utils';

import ChatStatsRows from '@/components/chat/ChatStatsRows.vue';
import { setPreferredLocale } from '@/i18n';
import {
  combineUsageWithSubchats,
  formatStepDurationMs,
  formatTokensPerSecond,
  subtractIncludedTokens,
} from '@/utils/stepStats';

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

  it('renders labeled columns side by side for every metric row', () => {
    const wrapper = mount(ChatStatsRows, {
      props: {
        columns: [
          { key: 'own', label: 'Own', stats: { input_tokens: 100, cached_input_tokens: 40, cost: 0.5 } },
          { key: 'all', label: 'All', stats: { input_tokens: 300, cached_input_tokens: 90, cost: 1.25 } },
        ],
      },
    });

    expect(wrapper.get('.chat-stats-header').findAll('.chat-stats-value').map((cell) => cell.text())).toEqual([
      'Own',
      'All',
    ]);
    const rows = wrapper.findAll('.chat-stats-row');
    expect(rows).toHaveLength(9);
    for (const row of rows) expect(row.findAll('.chat-stats-value')).toHaveLength(2);

    const values = (label: string) =>
      rows
        .find((row) => row.get('.chat-stats-label').text() === label)!
        .findAll('.chat-stats-value')
        .map((cell) => cell.text());
    expect(values('Input tokens (total)')).toEqual(['100', '300']);
    expect(values('Cold input tokens')).toEqual(['60', '210']);
    expect(values('Cost (USD)')).toEqual(['0.500000', '1.250000']);
  });

  it('keeps the single-column layout without a header when no columns are given', () => {
    const wrapper = mount(ChatStatsRows, { props: { stats: { input_tokens: 5 } } });

    expect(wrapper.find('.chat-stats-header').exists()).toBe(false);
    expect(wrapper.classes()).not.toContain('chat-stats-rows--multi');
  });

  it('adds subchat tokens and cost but leaves latency and speed unknown', () => {
    expect(
      combineUsageWithSubchats(
        { input_tokens: 100, output_tokens: 20, cached_input_tokens: null, time_to_first_token_ms: 300,
          tokens_per_second: 40, cost: 0.1 },
        { input_tokens: 900, output_tokens: null, cached_input_tokens: 500, reasoning_tokens: null, cost: 0.4 }
      )
    ).toEqual({
      input_tokens: 1000,
      output_tokens: 20,
      cached_input_tokens: 500,
      reasoning_tokens: null,
      time_to_first_token_ms: null,
      tokens_per_second: null,
      cost: 0.5,
    });
  });

  it('clamps inconsistent included counts instead of showing negative tokens', () => {
    expect(subtractIncludedTokens(10, 12)).toBe(0);
    expect(subtractIncludedTokens(10, null)).toBeNull();
  });

  it('renders unavailable latency and throughput as unknown', () => {
    expect(formatStepDurationMs(null)).toBe('—');
    expect(formatTokensPerSecond(null)).toBe('—');
  });
});
