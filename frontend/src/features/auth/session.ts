import { computed, ref } from 'vue';
import { api, isHttpError } from '@/api/client';
import type { SessionUser } from '@/types/api';

const currentUser = ref<SessionUser | null>(null);
const initialized = ref(false);
let refreshPromise: Promise<SessionUser | null> | null = null;

const isAuthenticated = computed(() => Boolean(currentUser.value));

const parseInitialUserFromDom = (): SessionUser | null => {
  const host = document.getElementById('spa-root') as HTMLElement | null;
  if (!host) return null;

  const id = Number(host.dataset.currentUserId || '');
  const username = String(host.dataset.currentUserUsername || '').trim();
  const isAdminRaw = String(host.dataset.currentUserIsAdmin || '').trim();
  const isAdmin = isAdminRaw === 'true';

  if (!Number.isFinite(id) || id <= 0 || username === '') return null;

  return { id, username, is_admin: isAdmin };
};

export const ensureAuthInitialized = () => {
  if (initialized.value) return;
  currentUser.value = parseInitialUserFromDom();
  initialized.value = true;
};

export const useSessionAuth = () => ({
  currentUser,
  initialized,
  isAuthenticated,
});

export const signIn = async (username: string, password: string): Promise<SessionUser> => {
  const payload = await api.post<{ user: SessionUser }>(
    '/api/bff/auth/login',
    { username, password },
    { redirectOnUnauthorized: false }
  );

  currentUser.value = payload.user;
  initialized.value = true;
  return payload.user;
};

export const fetchCurrentUser = async (): Promise<SessionUser> => {
  const payload = await api.get<{ user: SessionUser }>('/api/bff/auth/me', {
    redirectOnUnauthorized: false,
  });

  currentUser.value = payload.user;
  initialized.value = true;
  return payload.user;
};

export const refreshSessionUser = async (): Promise<SessionUser | null> => {
  if (refreshPromise) return refreshPromise;

  refreshPromise = (async () => {
    try {
      return await fetchCurrentUser();
    } catch (error) {
      if (isHttpError(error) && error.status === 401) {
        currentUser.value = null;
        initialized.value = true;
        return null;
      }

      throw error;
    } finally {
      refreshPromise = null;
    }
  })();

  return refreshPromise;
};

export const signOut = async (): Promise<void> => {
  await api.post('/api/bff/auth/logout', {});
  currentUser.value = null;
  initialized.value = true;
};
