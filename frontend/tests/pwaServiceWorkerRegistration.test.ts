describe('service worker registration', () => {
  const registration = {} as ServiceWorkerRegistration;

  beforeEach(() => {
    vi.resetModules();
    document.head.innerHTML = '';
    delete window.__IC_SERVICE_WORKER_REGISTRATION__;
  });

  it('reuses the registration started by the inline bootstrap supervisor', async () => {
    const register = vi.fn();
    Object.defineProperty(navigator, 'serviceWorker', {
      configurable: true,
      value: {
        register,
        getRegistration: vi.fn(),
        controller: null,
      },
    });
    window.__IC_SERVICE_WORKER_REGISTRATION__ = Promise.resolve(registration);

    const { registerServiceWorker } = await import('@/features/pwa/serviceWorker');

    await expect(registerServiceWorker()).resolves.toBe(registration);
    expect(register).not.toHaveBeenCalled();
  });

  it('uses a stable script URL and bypasses HTTP cache when registering directly', async () => {
    const meta = document.createElement('meta');
    meta.name = 'ic-build-id';
    meta.content = '/assets/js/spa-digest.js?vsn=d';
    document.head.append(meta);

    const register = vi.fn().mockResolvedValue(registration);
    Object.defineProperty(navigator, 'serviceWorker', {
      configurable: true,
      value: {
        register,
        getRegistration: vi.fn().mockResolvedValue(null),
        controller: null,
      },
    });

    const { registerServiceWorker } = await import('@/features/pwa/serviceWorker');

    await expect(registerServiceWorker()).resolves.toBe(registration);
    expect(register).toHaveBeenCalledWith(
      '/service-worker.js',
      {
        scope: '/',
        updateViaCache: 'none',
      }
    );
  });
});
