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

      <RouterLink class="card catalog-card" to="/catalogs/knowledge-tags">
        <div class="catalog-card__title">Knowledge Tags</div>
        <div class="muted">Hierarchical tags for organizing your knowledge base.</div>
      </RouterLink>

      <RouterLink class="card catalog-card" to="/catalogs/bots">
        <div class="catalog-card__title">Bots</div>
        <div class="muted">Bot profiles with defaults and attached knowledge blocks.</div>
      </RouterLink>

      <RouterLink class="card catalog-card" to="/catalogs/llm-providers">
        <div class="catalog-card__title">LLM Providers</div>
        <div class="muted">Provider endpoints and API keys.</div>
      </RouterLink>

      <RouterLink class="card catalog-card" to="/catalogs/llm-configurations">
        <div class="catalog-card__title">LLM Configurations</div>
        <div class="muted">Models, parameters, and capabilities used by generation.</div>
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

