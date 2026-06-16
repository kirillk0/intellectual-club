import type { RouteLocationNormalizedLoaded } from 'vue-router';
import { isStandalonePwa } from '@/pwa';

const STORAGE_KEY = 'intellectual-club:pwa:last-route';
const CHAT_LIST_PATH = '/chats';
const EXCLUDED_ROUTE_NAMES = new Set(['login', 'outlet-connect']);

let initialRestoreChecked = false;

const storageAvailable = () => {
  try {
    return typeof window.localStorage !== 'undefined';
  } catch {
    return false;
  }
};

const pwaRoutePersistenceEnabled = () => isStandalonePwa() && storageAvailable();

const routeName = (route: RouteLocationNormalizedLoaded) =>
  typeof route.name === 'string' ? route.name : '';

const safeStoredPath = (value: string | null): string | null => {
  if (!value || !value.startsWith('/') || value.startsWith('//')) return null;

  try {
    const url = new URL(value, window.location.origin);
    if (url.origin !== window.location.origin) return null;

    const fullPath = `${url.pathname}${url.search}${url.hash}`;
    if (url.pathname === '/' || url.pathname === '/login' || url.pathname.startsWith('/login/')) return null;
    if (url.pathname === '/outlets/connect') return null;

    return fullPath;
  } catch {
    return null;
  }
};

const chatListStoredPath = (value: string): string | null => {
  if (!value.startsWith('/') || value.startsWith('//')) return null;

  try {
    const url = new URL(value, window.location.origin);
    if (url.origin !== window.location.origin) return null;
    if (url.pathname !== '/' && url.pathname !== CHAT_LIST_PATH) return null;

    return `${CHAT_LIST_PATH}${url.search}${url.hash}`;
  } catch {
    return null;
  }
};

const routeStoredPath = (route: RouteLocationNormalizedLoaded): string | null => {
  if (routeName(route) === 'chats') return chatListStoredPath(route.fullPath);
  return safeStoredPath(route.fullPath);
};

export const restorePwaRouteOnLaunch = (route: RouteLocationNormalizedLoaded): string | null => {
  if (initialRestoreChecked) return null;
  initialRestoreChecked = true;

  if (!pwaRoutePersistenceEnabled()) return null;
  if (route.fullPath !== '/') return null;

  try {
    return safeStoredPath(window.localStorage.getItem(STORAGE_KEY));
  } catch {
    return null;
  }
};

export const rememberPwaRoute = (route: RouteLocationNormalizedLoaded, authenticated: boolean) => {
  if (!authenticated || !pwaRoutePersistenceEnabled()) return;
  if (EXCLUDED_ROUTE_NAMES.has(routeName(route))) return;

  const fullPath = routeStoredPath(route);
  if (!fullPath) return;

  try {
    window.localStorage.setItem(STORAGE_KEY, fullPath);
  } catch {
    // Ignore private mode storage failures.
  }
};

export const clearStoredPwaRoute = () => {
  if (!storageAvailable()) return;

  try {
    window.localStorage.removeItem(STORAGE_KEY);
  } catch {
    // Ignore private mode storage failures.
  }
};
