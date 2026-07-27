import { getAttachmentPreviewKind } from '@/features/chat/attachments';

describe('getAttachmentPreviewKind', () => {
  it.each([
    ['page.html', 'text/html', false],
    ['page.txt', 'text/html; charset=utf-8', false],
    ['page.xhtml', 'application/xhtml+xml', false],
    ['PAGE.HTML', 'application/octet-stream', false],
    ['page.htm', '', false],
    ['page.xhtml', 'application/octet-stream', false],
  ])('recognizes %s with MIME %s as HTML', (name, mimeType, isImage) => {
    expect(getAttachmentPreviewKind(name, mimeType, isImage)).toBe('html');
  });

  it.each([
    ['image.html', 'text/html', true, 'image'],
    ['readme.md', 'text/markdown', false, 'markdown'],
    ['readme.markdown', 'application/octet-stream', false, 'markdown'],
    ['notes.txt', 'text/plain', false, 'text'],
    ['data.json', 'application/json', false, 'text'],
    ['archive.zip', 'application/zip', false, 'binary'],
  ])('keeps %s classified as %s', (name, mimeType, isImage, expected) => {
    expect(getAttachmentPreviewKind(name, mimeType, isImage)).toBe(expected);
  });
});
