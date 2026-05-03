<template>
  <section class="card llm-configuration-nav-card">
    <div class="tabs">
      <RouterLink class="tab" :class="{ active: configurationsActive }" to="/catalogs/llm-configurations">
        Configurations
      </RouterLink>
      <RouterLink class="tab" :class="{ active: providersActive }" to="/catalogs/llm-providers">
        Providers
      </RouterLink>
    </div>
  </section>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import { RouterLink, useRoute } from 'vue-router';

const route = useRoute();

const configurationsActive = computed(() => {
  const name = String(route.name || '');
  return name === 'llm-configurations' || name === 'llm-configuration' || name === 'llm-configuration-usage';
});

const providersActive = computed(() => {
  const name = String(route.name || '');
  return name === 'llm-providers' || name === 'llm-provider';
});
</script>

<style scoped>
.llm-configuration-nav-card {
  padding: 10px;
}

.llm-configuration-nav-card .tabs {
  margin: 0;
}

.llm-configuration-nav-card :deep(a.tab) {
  text-decoration: none;
}
</style>
