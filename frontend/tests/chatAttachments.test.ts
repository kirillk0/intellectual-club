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
    ['clip.mp4', 'video/mp4', false, 'video'],
    ['clip.bin', 'Video/WebM; codecs=vp9', false, 'video'],
    ['sound.mp3', 'audio/mpeg', false, 'audio'],
    ['sound.bin', 'Audio/Ogg; codecs=opus', false, 'audio'],
    ['document.pdf', 'application/pdf', false, 'pdf'],
    ['document.bin', ' APPLICATION/PDF ; version=1.7', false, 'pdf'],
    ['unknown.mp4', 'application/octet-stream', false, 'binary'],
    ['archive.zip', 'application/zip', false, 'binary'],
  ])('keeps %s classified as %s', (name, mimeType, isImage, expected) => {
    expect(getAttachmentPreviewKind(name, mimeType, isImage)).toBe(expected);
  });
});
