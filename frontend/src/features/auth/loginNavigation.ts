export const loginUrlForLocation = (
  location: Pick<Location, 'pathname' | 'search' | 'hash'>
) => {
  if (location.pathname === '/login') return '/login';

  const next = `${location.pathname}${location.search}${location.hash}`;
  const params = new URLSearchParams({ next });
  return `/login?${params.toString()}`;
};

export const navigateToLoginWithReturn = () => {
  if (window.location.pathname === '/login') return;
  window.location.assign(loginUrlForLocation(window.location));
};
