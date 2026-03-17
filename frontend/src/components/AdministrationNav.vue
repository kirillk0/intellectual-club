<template>
  <section class="card administration-nav-card">
    <div class="tabs">
      <RouterLink class="tab" :class="{ active: usersActive }" to="/administration/users">Users</RouterLink>
      <RouterLink class="tab" :class="{ active: groupsActive }" to="/administration/user-groups">Groups</RouterLink>
    </div>
  </section>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import { RouterLink, useRoute } from 'vue-router';

const route = useRoute();

const usersActive = computed(() => {
  const name = String(route.name || '');
  return name === 'admin-users' || name === 'admin-user';
});

const groupsActive = computed(() => {
  const name = String(route.name || '');
  return name === 'admin-user-groups' || name === 'admin-user-group';
});
</script>

<style scoped>
.administration-nav-card {
  padding: 10px;
}

.administration-nav-card .tabs {
  margin: 0;
}

.administration-nav-card :deep(a.tab) {
  text-decoration: none;
}
</style>
