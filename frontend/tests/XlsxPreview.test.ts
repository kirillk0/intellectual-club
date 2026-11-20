import { flushPromises, mount } from '@vue/test-utils';
import readExcelFile from 'read-excel-file/browser';

import XlsxPreview from '@/components/chat/XlsxPreview.vue';

vi.mock('read-excel-file/browser', () => ({ default: vi.fn() }));

const open = () => mount(XlsxPreview, { props: { file: new Blob(), title: 'Budget.xlsx' } });

describe('XlsxPreview', () => {
  it('shows only the selected sheet and treats labels and values as text', async () => {
    vi.mocked(readExcelFile).mockResolvedValue([
      { sheet: 'Data', data: [[0, false, new Date('2025-03-02T00:00:00.000Z'), null, '<img src=x>']] },
      { sheet: '<b>Other</b>', data: [[new Date('2025-03-02T06:00:00.000Z')]] },
      { sheet: 'Empty', data: [] },
    ]);
    const wrapper = open();
    await flushPromises();
    expect(wrapper.emitted('ready')).toHaveLength(1);
    expect(wrapper.findAll('tbody td').map(cell => cell.text())).toEqual(['0', 'FALSE', '2025-03-02', '', '<img src=x>']);
    expect(wrapper.find('img, b').exists()).toBe(false);
    await wrapper.get('select').setValue(1);
    expect(wrapper.findAll('tbody td').map(cell => cell.text())).toEqual(['2025-03-02 06:00:00']);
    await wrapper.get('select').setValue(2);
    expect(wrapper.text()).toContain('This worksheet is empty.');
    expect(wrapper.find('table').exists()).toBe(false);
    wrapper.unmount();
  });

  it('caps the rendered rows and columns and tells the user about the limit', async () => {
    vi.mocked(readExcelFile).mockResolvedValue([{ sheet: 'Large', data: Array.from({ length: 205 }, () => Array(40).fill('value')) }]);
    const wrapper = open();
    await flushPromises();
    expect(wrapper.get('[role="status"]').text()).toContain('200 rows and 32 columns');
    expect(wrapper.findAll('tbody tr')).toHaveLength(200);
    expect(wrapper.findAll('thead th').at(-1)?.text()).toBe('AF');
    expect(wrapper.findAll('tbody td')).toHaveLength(200 * 32);
    wrapper.unmount();
  });

  it('reports a failed parse to the preview modal', async () => {
    vi.mocked(readExcelFile).mockRejectedValue(new Error('Invalid file'));
    const wrapper = open();
    await flushPromises();
    expect(wrapper.emitted('error')).toHaveLength(1);
    expect(wrapper.emitted('ready')).toBeUndefined();
    wrapper.unmount();
  });
});
