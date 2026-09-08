import { renderChatMessageHtml } from '@/utils/chatMarkdown';

const fileId = 'c6012361-90b8-4f6b-afb0-35729ae584c6';
const otherFileId = '297cb6da-fb30-4c54-8110-b8352e6ea639';
const fileUrl = `/api/bff/chat-files/${fileId}`;

function render(markdown: string, attachmentLinks = true) {
  const root = document.createElement('div');
  root.innerHTML = renderChatMessageHtml(markdown, { attachmentLinks });
  return root;
}

describe('chat Markdown attachment references', () => {
  it('renders download links and inline images with their labels and titles', () => {
    const root = render(`[Download signature](file://${fileId} "Original")\n\n![Signature](file://${fileId})`);
    const anchor = root.querySelector('a')!;
    const image = root.querySelector('img')!;

    expect(anchor.getAttribute('href')).toBe(fileUrl);
    expect(anchor.hasAttribute('download')).toBe(true);
    expect(anchor.hasAttribute('target')).toBe(false);
    expect(anchor.textContent).toBe('Download signature');
    expect(anchor.title).toBe('Original');
    expect(image.getAttribute('src')).toBe(`${fileUrl}?inline=1`);
    expect(image.alt).toBe('Signature');
    expect(image.classList.contains('chat-attachment-image')).toBe(true);
  });

  it('supports reference-style Markdown, multiple files and uppercase UUIDs', () => {
    const root = render(`[First][file]\n\n![Second](file://${otherFileId})\n\n[file]: file://${fileId.toUpperCase()}`);

    expect(root.querySelector('a')?.getAttribute('href')).toBe(fileUrl);
    expect(root.querySelector('img')?.getAttribute('src')).toBe(`/api/bff/chat-files/${otherFileId}?inline=1`);
  });

  it('leaves code examples literal', () => {
    const example = `[Download](file://${fileId})`;
    const root = render(`\`${example}\`\n\n\`\`\`markdown\n![Example](file://${fileId})\n\`\`\``);

    expect(root.querySelector('code')?.textContent).toBe(example);
    expect(root.querySelector('pre code')?.textContent).toContain(`file://${fileId}`);
    expect(root.querySelector('a, img')).toBeNull();
  });

  it.each([
    'file:///etc/passwd',
    'file://localhost/etc/passwd',
    'file://not-a-uuid',
    `file://${fileId}/extra`,
    `file://${fileId}?inline=1`,
    `file://${fileId}#fragment`,
  ])('does not allow unsupported file references: %s', (url) => {
    const root = render(`[File](${url})\n\n![Fallback](${url})`);

    expect(root.querySelector('a')?.hasAttribute('href')).toBe(false);
    expect(root.querySelector('img')?.hasAttribute('src')).toBe(false);
    expect(root.querySelector('img')?.alt).toBe('Fallback');
  });

  it('preserves external links and sanitizes dangerous HTML and URL schemes', () => {
    const root = render(`[Web](https://example.com)\n\n<a href="javascript:alert(1)">Unsafe</a>\n<img src="file://${fileId}" onerror="alert(1)"><script>alert(1)</script>`);
    const anchors = root.querySelectorAll('a');

    expect(anchors[0]?.getAttribute('href')).toBe('https://example.com');
    expect(anchors[0]?.getAttribute('target')).toBe('_blank');
    expect(anchors[0]?.getAttribute('rel')).toContain('noopener');
    expect(anchors[1]?.hasAttribute('href')).toBe(false);
    expect(root.querySelector('[onerror], script')).toBeNull();
  });

  it('keeps file references disabled outside live message rendering', () => {
    const root = render(`[File](file://${fileId})\n\n![Image](file://${fileId})`, false);

    expect(root.innerHTML).not.toContain('/api/bff/chat-files/');
    expect(root.querySelector('a')?.hasAttribute('href')).toBe(false);
    expect(root.querySelector('img')?.hasAttribute('src')).toBe(false);
  });
});
