const sessionMocks = vi.hoisted(() => ({
  get: vi.fn(),
  navigateToLogin: vi.fn(),
}));

vi.mock('@/api/client', () => ({
  api: {
    get: sessionMocks.get,
  },
  isHttpError: (error: unknown) =>
    Boolean(
      error &&
        typeof error === 'object' &&
        (error as { name?: unknown }).name === 'HttpError'
    ),
}));
vi.mock('@/features/auth/loginNavigation', () => ({
  navigateToLoginWithReturn: sessionMocks.navigateToLogin,
}));
vi.mock('@/features/app/theme', () => ({
  normalizePreferredTheme: () => 'system',
  setPreferredTheme: vi.fn(),
}));
vi.mock('@/features/push/webPush', () => ({
  cleanupWebPushForLogout: vi.fn(),
}));
vi.mock('@/features/pwa/lastRoute', () => ({
  clearStoredPwaRoute: vi.fn(),
}));
vi.mock('@/i18n', () => ({
  normalizePreferredLocale: () => null,
  setPreferredLocale: vi.fn(),
}));

describe('session recovery', () => {
  beforeEach(() => {
    vi.resetModules();
    sessionMocks.get.mockReset();
    sessionMocks.navigateToLogin.mockReset();
  });

  it('sends a terminal 401 to login instead of leaving a protected route open', async () => {
    sessionMocks.get.mockRejectedValue({
      name: 'HttpError',
      status: 401,
    });

    const { refreshSessionUser, useSessionAuth } = await import(
      '@/features/auth/session'
    );
    await expect(refreshSessionUser()).resolves.toBeNull();

    expect(useSessionAuth().isAuthenticated.value).toBe(false);
    expect(sessionMocks.navigateToLogin).toHaveBeenCalledTimes(1);
  });
});

describe('login recovery URL', () => {
  it('preserves the complete protected deep link', async () => {
    vi.doUnmock('@/features/auth/loginNavigation');
    const { loginUrlForLocation } = await import(
      '@/features/auth/loginNavigation'
    );

    expect(
      loginUrlForLocation({
        pathname: '/catalogs/bots',
        search: '?tab=shared',
        hash: '#bot-12',
      })
    ).toBe(
      '/login?next=%2Fcatalogs%2Fbots%3Ftab%3Dshared%23bot-12'
    );
  });
});
