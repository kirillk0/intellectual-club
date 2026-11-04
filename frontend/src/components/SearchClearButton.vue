<template>
  <button type="button" class="search-icon-button search-clear-button" :aria-label="t('Clear search')" :title="t('Clear search')">
    <SvgIcon name="x" size="16" />
  </button>
</template>

<script setup lang="ts">
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { translate as t } from '@/i18n';
</script>
