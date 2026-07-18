import {
  clearBackendStatusBanner,
  showBackendStatusBanner,
  useBackendStatusBanner,
} from '@/features/app/backendStatusBanner';

describe('backend status banner', () => {
  const firstKey = 'test:first';
  const secondKey = 'test:second';

  afterEach(() => {
    clearBackendStatusBanner(firstKey);
    clearBackendStatusBanner(secondKey);
  });

  it('does not let an unrelated successful task clear an active incident', () => {
    const { banner } = useBackendStatusBanner();

    showBackendStatusBanner({ title: 'Offline', message: 'First request failed.' }, firstKey);
    clearBackendStatusBanner(secondKey);

    expect(banner.value).toEqual({
      title: 'Offline',
      message: 'First request failed.',
    });
  });

  it('reveals the previous incident when the newest task recovers', () => {
    const { banner } = useBackendStatusBanner();

    showBackendStatusBanner({ title: 'Offline', message: 'First request failed.' }, firstKey);
    showBackendStatusBanner({ title: 'Server error', message: 'Second request failed.' }, secondKey);
    clearBackendStatusBanner(secondKey);

    expect(banner.value).toEqual({
      title: 'Offline',
      message: 'First request failed.',
    });
  });
});
