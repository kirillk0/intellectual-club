<template>
  <div class="card" style="max-width: 560px; margin: 40px auto;">
    <h2>Connect outlet</h2>
    <p class="muted" style="margin-top: 6px;">
      Approve an outlet runner to connect it to your account.
    </p>

    <div v-if="approved" class="stack" style="margin-top: 16px;">
      <div class="success-text">Approved.</div>
      <div class="muted">
        You can return to the outlet application. The outlet runner will receive the token automatically.
      </div>
      <div class="flex" style="gap: 10px; flex-wrap: wrap;">
        <RouterLink
          v-if="toolInstanceId"
          class="button"
          :to="`/catalogs/tools/${toolInstanceId}`"
        >
          Open tool
        </RouterLink>
        <button type="button" class="button" @click="reset">
          Approve another
        </button>
      </div>
    </div>

    <form v-else class="stack" style="margin-top: 16px;" @submit.prevent="approve">
      <label>
        Code
        <input
          v-model="code"
          class="full"
          autocomplete="one-time-code"
          placeholder="ABCD-EFGH"
          @input="error = ''"
        />
      </label>
      <label>
        Tool name (optional)
        <input v-model="toolName" class="full" placeholder="Outlet" @input="error = ''" />
        <div class="muted" style="font-size: 0.85rem;">
          Leave empty to use the default name suggested by the server.
        </div>
      </label>

      <div v-if="error" class="error-text">{{ error }}</div>

      <button type="submit" class="primary" :disabled="loading">
        {{ loading ? 'Approving…' : 'Approve' }}
      </button>
    </form>
  </div>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue';
import { useRoute } from 'vue-router';
import { api, isHttpError } from '@/api/client';

const route = useRoute();

const initialCode = computed(() => String(route.query.code || '').trim());

const code = ref(initialCode.value);
const toolName = ref('');
const loading = ref(false);
const error = ref('');
const approved = ref(false);
const toolInstanceId = ref<number | null>(null);

function normalizeCode(value: string) {
  return String(value || '')
    .trim()
    .toUpperCase()
    .replace(/\s+/g, '');
}

async function approve() {
  error.value = '';
  const userCode = normalizeCode(code.value);
  if (!userCode) {
    error.value = 'Code is required.';
    return;
  }

  loading.value = true;
  try {
    const payload = await api.post<{
      status: string;
      tool_instance_id?: number;
      tool_name?: string;
      error?: string;
    }>('/api/outlet/pair/approve/', {
      user_code: userCode,
      tool_name: toolName.value.trim() || undefined,
    });

    toolInstanceId.value = typeof payload.tool_instance_id === 'number' ? payload.tool_instance_id : null;
    approved.value = true;
  } catch (e) {
    console.error(e);
    const message =
      isHttpError(e) && e.bodyJson && typeof (e.bodyJson as any)?.error === 'string'
        ? String((e.bodyJson as any).error)
        : e instanceof Error
          ? e.message
          : 'Failed to approve pairing.';

    error.value = message;
  } finally {
    loading.value = false;
  }
}

function reset() {
  approved.value = false;
  toolInstanceId.value = null;
  toolName.value = '';
  error.value = '';
  code.value = '';
}
</script>
