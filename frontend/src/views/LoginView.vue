<template>
  <section class="login-page">
    <div class="login-card">
      <h1>Sign in</h1>
      <p class="muted">Use your account credentials to continue.</p>

      <form class="login-form" @submit.prevent="submit">
        <label>
          <span>Username</span>
          <input
            v-model="username"
            type="text"
            autocomplete="username"
            autocapitalize="off"
            autocorrect="off"
            spellcheck="false"
            required
          />
        </label>

        <label>
          <span>Password</span>
          <input
            v-model="password"
            type="password"
            autocomplete="current-password"
            required
          />
        </label>

        <p v-if="error" class="error-text">{{ error }}</p>

        <button type="submit" class="primary" :disabled="loading">
          {{ loading ? 'Signing in...' : 'Sign in' }}
        </button>
      </form>
    </div>
  </section>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { HttpError, isHttpError } from '@/api/client';
import { ensureAuthInitialized, signIn, useSessionAuth } from '@/features/auth/session';

const router = useRouter();
const route = useRoute();

ensureAuthInitialized();

const { isAuthenticated } = useSessionAuth();
if (isAuthenticated.value) {
  void router.replace('/');
}

const username = ref('');
const password = ref('');
const loading = ref(false);
const error = ref('');

const nextPath = computed(() => {
  const raw = route.query.next;
  if (typeof raw !== 'string') return '/';
  if (!raw.startsWith('/')) return '/';
  if (raw.startsWith('/login')) return '/';
  return raw;
});

const messageFromHttpError = (httpError: HttpError): string => {
  if (httpError.status === 401) {
    const detail = (httpError.bodyJson as { detail?: unknown } | null)?.detail;
    if (typeof detail === 'string' && detail.trim() !== '') return detail.trim();
    return 'Incorrect username or password.';
  }

  const detail = (httpError.bodyJson as { detail?: unknown } | null)?.detail;
  if (typeof detail === 'string' && detail.trim() !== '') return detail.trim();
  return httpError.message || 'Failed to sign in.';
};

const submit = async () => {
  if (loading.value) return;

  loading.value = true;
  error.value = '';

  try {
    await signIn(username.value, password.value);
    await router.replace(nextPath.value);
  } catch (cause) {
    if (isHttpError(cause)) {
      error.value = messageFromHttpError(cause);
    } else {
      error.value = cause instanceof Error ? cause.message : 'Failed to sign in.';
    }
  } finally {
    loading.value = false;
  }
};
</script>

<style scoped>
.login-page {
  min-height: calc(100vh - 24px);
  display: grid;
  place-items: center;
  padding: 20px;
}

.login-card {
  width: min(420px, 100%);
  border: 1px solid #e6e6e6;
  border-radius: 12px;
  background: #fff;
  padding: 18px;
  box-shadow: 0 8px 26px rgba(17, 24, 39, 0.06);
}

.login-card h1 {
  margin: 0 0 4px;
  font-size: 1.45rem;
}

.login-card .muted {
  margin: 0 0 14px;
}

.login-form {
  display: grid;
  gap: 10px;
}

.login-form label {
  display: grid;
  gap: 6px;
}

.login-form input {
  width: 100%;
}

.login-form button {
  width: 100%;
  margin-top: 4px;
}

.error-text {
  margin: 0;
  color: #b42318;
  font-size: 0.92rem;
}
</style>
