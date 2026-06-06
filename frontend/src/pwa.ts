const SERVICE_WORKER_PATH = '/service-worker.js';
const DISPLAY_MODE_QUERIES = [
  '(display-mode: standalone)',
  '(display-mode: fullscreen)',
  '(display-mode: minimal-ui)',
] as const;
const DISABLED_SCALE_VIEWPORT_DIRECTIVES = ['maximum-scale=1', 'user-scalable=no'] as const;
const IOS_GESTURE_EVENTS = ['gesturestart', 'gesturechange', 'gestureend'] as const;
const NON_PASSIVE_EVENT_OPTIONS: AddEventListenerOptions = { passive: false };
const SCALE_DIRECTIVE_PATTERN = /^(maximum-scale|user-scalable)\s*=/i;

type NavigatorWithStandalone = Navigator & {
  standalone?: boolean;
};

let initialViewportContent: string | null = null;
let initialRootTouchAction: string | null = null;
let initialBodyTouchAction: string | null = null;
let zoomBehaviorSetup = false;

const isStandalonePwa = () =>
  DISPLAY_MODE_QUERIES.some((query) => window.matchMedia(query).matches) ||
  (navigator as NavigatorWithStandalone).standalone === true;

const getViewportMeta = () => document.querySelector<HTMLMetaElement>('meta[name="viewport"]');

const getViewportWithZoomDisabled = (content: string) => {
  const viewportDirectives = content
    .split(',')
    .map((directive) => directive.trim())
    .filter((directive) => directive && !SCALE_DIRECTIVE_PATTERN.test(directive));

  return [...viewportDirectives, ...DISABLED_SCALE_VIEWPORT_DIRECTIVES].join(', ');
};

const registerServiceWorker = () => {
  if (!('serviceWorker' in navigator)) return;

  navigator.serviceWorker.register(SERVICE_WORKER_PATH, { scope: '/' }).catch((error) => {
    console.warn('Service worker registration failed.', error);
  });
};

const syncStandaloneZoomBehavior = () => {
  const standalone = isStandalonePwa();
  const viewport = getViewportMeta();

  if (viewport) {
    initialViewportContent ??= viewport.content;
    viewport.content = standalone
      ? getViewportWithZoomDisabled(initialViewportContent)
      : initialViewportContent;
  }

  if (standalone) {
    initialRootTouchAction ??= document.documentElement.style.touchAction;
    document.documentElement.style.touchAction = 'pan-x pan-y';

    if (document.body) {
      initialBodyTouchAction ??= document.body.style.touchAction;
      document.body.style.touchAction = 'pan-x pan-y';
    }

    return;
  }

  if (initialRootTouchAction !== null) {
    document.documentElement.style.touchAction = initialRootTouchAction;
  }

  if (document.body && initialBodyTouchAction !== null) {
    document.body.style.touchAction = initialBodyTouchAction;
  }
};

const preventStandalonePinchZoom = (event: TouchEvent) => {
  if (isStandalonePwa() && event.touches.length > 1) {
    event.preventDefault();
  }
};

const preventStandaloneGestureZoom = (event: Event) => {
  if (isStandalonePwa()) {
    event.preventDefault();
  }
};

const addDisplayModeListener = (mediaQuery: MediaQueryList) => {
  const listener = () => syncStandaloneZoomBehavior();
  const legacyMediaQuery = mediaQuery as MediaQueryList & {
    addListener?: (listener: () => void) => void;
  };

  if (typeof mediaQuery.addEventListener === 'function') {
    mediaQuery.addEventListener('change', listener);
    return;
  }

  legacyMediaQuery.addListener?.(listener);
};

const setupStandaloneZoomBehavior = () => {
  syncStandaloneZoomBehavior();

  if (zoomBehaviorSetup) return;
  zoomBehaviorSetup = true;

  DISPLAY_MODE_QUERIES.map((query) => window.matchMedia(query)).forEach(addDisplayModeListener);
  window.addEventListener('pageshow', syncStandaloneZoomBehavior);
  document.addEventListener('touchstart', preventStandalonePinchZoom, NON_PASSIVE_EVENT_OPTIONS);
  document.addEventListener('touchmove', preventStandalonePinchZoom, NON_PASSIVE_EVENT_OPTIONS);

  IOS_GESTURE_EVENTS.forEach((eventName) => {
    document.addEventListener(eventName, preventStandaloneGestureZoom, NON_PASSIVE_EVENT_OPTIONS);
  });
};

export const setupPwa = () => {
  setupStandaloneZoomBehavior();

  if (document.readyState === 'complete') {
    registerServiceWorker();
    return;
  }

  window.addEventListener('load', registerServiceWorker, { once: true });
};
