export const routeDocumentUrl = (
  target: string,
  origin = window.location.origin
) => new URL(target, origin).href;

export const navigateDocumentToRoute = (target: string) => {
  window.location.replace(routeDocumentUrl(target));
};
