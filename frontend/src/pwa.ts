const SERVICE_WORKER_PATH = '/service-worker.js';

const registerServiceWorker = () => {
  if (!('serviceWorker' in navigator)) return;

  navigator.serviceWorker.register(SERVICE_WORKER_PATH, { scope: '/' }).catch((error) => {
    console.warn('Service worker registration failed.', error);
  });
};

export const setupPwa = () => {
  if (document.readyState === 'complete') {
    registerServiceWorker();
    return;
  }

  window.addEventListener('load', registerServiceWorker, { once: true });
};
