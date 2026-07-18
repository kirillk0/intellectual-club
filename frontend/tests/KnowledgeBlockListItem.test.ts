import { mount } from '@vue/test-utils';
import { afterEach, describe, expect, it } from 'vitest';

import KnowledgeBlockListItem from '@/components/KnowledgeBlockListItem.vue';
import { setPreferredLocale } from '@/i18n';

describe('KnowledgeBlockListItem', () => {
  afterEach(() => setPreferredLocale(null));

  it('keeps the version with token details instead of the title or controls', () => {
    setPreferredLocale('en');
    const wrapper = mount(KnowledgeBlockListItem, {
      props: {
        name: 'System instructions',
        version: 'A very long version label',
        tokenCount: 1223,
      },
      slots: {
        leading: '<input type="checkbox">',
        actions: '<button type="button">Delete</button>',
      },
    });

    const details = wrapper.get('.kb-list-item__details');
    expect(details.get('.kb-list-item__tokens-full').text()).toBe('~1,223 tokens');
    expect(details.get('.kb-list-item__tokens-compact').text()).toBe('~1,223 tok.');
    expect(details.get('.kb-list-item__version').text()).toBe('A very long version label');
    expect(details.element.lastElementChild).toBe(details.get('.kb-list-item__version').element);
    expect(wrapper.find('.kb-list-item__title-line .kb-list-item__version').exists()).toBe(false);
    expect(wrapper.find('.kb-list-item__controls .kb-list-item__tokens').exists()).toBe(false);
  });
});
