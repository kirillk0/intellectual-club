<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Catalogs</strong>
      </div>
    </StackToolbarTeleport>

    <section class="grid-2">
      <RouterLink class="card catalog-card" to="/catalogs/knowledge-blocks">
        <div class="catalog-card__title">Knowledge Blocks</div>
        <div class="muted">Reusable content blocks attached to bots and configurations.</div>
      </RouterLink>

      <RouterLink class="card catalog-card" to="/catalogs/bots">
        <div class="catalog-card__title">Bots</div>
        <div class="muted">Bot profiles with defaults and attached knowledge blocks.</div>
      </RouterLink>

      <RouterLink class="card catalog-card" to="/catalogs/llm-configurations">
        <div class="catalog-card__title">LLM Configuration</div>
        <div class="muted">Models, parameters, provider endpoints, and API keys.</div>
      </RouterLink>
    </section>
  </div>
</template>

<script setup lang="ts">
import { RouterLink } from 'vue-router';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
</script>

<style scoped>
.catalog-card {
  display: flex;
  flex-direction: column;
  gap: 6px;
  transition: border-color 0.15s ease, transform 0.15s ease, box-shadow 0.15s ease;
}

.catalog-card:hover {
  border-color: #ddd;
  transform: translateY(-1px);
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.06);
  text-decoration: none;
}

.catalog-card__title {
  font-weight: 700;
}
</style>
