type DocumentScrollLockSnapshot = {
  scrollX: number;
  scrollY: number;
  rootOverflow: string;
  rootOverscrollBehavior: string;
  bodyPosition: string;
  bodyTop: string;
  bodyLeft: string;
  bodyRight: string;
  bodyWidth: string;
  bodyOverflow: string;
  bodyOverscrollBehavior: string;
  bodyPaddingRight: string;
};

let documentScrollLockCount = 0;
let documentScrollLockSnapshot: DocumentScrollLockSnapshot | null = null;

/**
 * Freezes document scrolling while an overlay covers the page. Calls are
 * reference-counted, so nested overlays share a single lock.
 */
export function lockDocumentScroll() {
  documentScrollLockCount += 1;
  if (documentScrollLockCount > 1) return;

  const root = document.documentElement;
  const body = document.body;
  const scrollX = window.scrollX;
  const scrollY = window.scrollY;
  const scrollbarWidth = root.clientWidth > 0 ? Math.max(0, window.innerWidth - root.clientWidth) : 0;
  const bodyPaddingRight = Number.parseFloat(window.getComputedStyle(body).paddingRight) || 0;

  documentScrollLockSnapshot = {
    scrollX,
    scrollY,
    rootOverflow: root.style.overflow,
    rootOverscrollBehavior: root.style.overscrollBehavior,
    bodyPosition: body.style.position,
    bodyTop: body.style.top,
    bodyLeft: body.style.left,
    bodyRight: body.style.right,
    bodyWidth: body.style.width,
    bodyOverflow: body.style.overflow,
    bodyOverscrollBehavior: body.style.overscrollBehavior,
    bodyPaddingRight: body.style.paddingRight,
  };

  root.style.overflow = 'hidden';
  root.style.overscrollBehavior = 'none';
  body.style.position = 'fixed';
  body.style.top = `-${scrollY}px`;
  body.style.left = `-${scrollX}px`;
  body.style.right = '0';
  body.style.width = '100%';
  body.style.overflow = 'hidden';
  body.style.overscrollBehavior = 'none';
  if (scrollbarWidth > 0) body.style.paddingRight = `${bodyPaddingRight + scrollbarWidth}px`;
}

/** Releases one lock taken by `lockDocumentScroll` and restores the scroll position after the last one. */
export function unlockDocumentScroll() {
  if (documentScrollLockCount === 0) return;
  documentScrollLockCount -= 1;
  if (documentScrollLockCount > 0) return;

  const snapshot = documentScrollLockSnapshot;
  documentScrollLockSnapshot = null;
  if (!snapshot) return;

  const root = document.documentElement;
  const body = document.body;
  root.style.overflow = snapshot.rootOverflow;
  root.style.overscrollBehavior = snapshot.rootOverscrollBehavior;
  body.style.position = snapshot.bodyPosition;
  body.style.top = snapshot.bodyTop;
  body.style.left = snapshot.bodyLeft;
  body.style.right = snapshot.bodyRight;
  body.style.width = snapshot.bodyWidth;
  body.style.overflow = snapshot.bodyOverflow;
  body.style.overscrollBehavior = snapshot.bodyOverscrollBehavior;
  body.style.paddingRight = snapshot.bodyPaddingRight;
  window.scrollTo(snapshot.scrollX, snapshot.scrollY);
}
