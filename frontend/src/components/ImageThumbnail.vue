<template>
  <div
    v-if="src || !hideWithoutImage"
    class="image-thumbnail"
    :class="[rounded ? 'image-thumbnail--rounded' : 'image-thumbnail--square']"
    :style="sizeStyle"
    aria-hidden="true"
  >
    <img v-if="src" :src="src" :alt="alt" />
    <span v-else>{{ fallback }}</span>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import { imageFallbackText, imageUrlWithVersion } from '@/features/media/image';
import type { ImageAsset } from '@/types/api';

const props = withDefaults(
  defineProps<{
    image?: ImageAsset | null;
    label?: string;
    alt?: string;
    size?: number;
    rounded?: boolean;
    hideWithoutImage?: boolean;
  }>(),
  {
    image: null,
    label: '',
    alt: '',
    size: 40,
    rounded: false,
    hideWithoutImage: false,
  }
);

const src = computed(() => imageUrlWithVersion(props.image));
const fallback = computed(() => imageFallbackText(props.label, '#'));
const sizeStyle = computed(() => ({
  width: `${props.size}px`,
  height: `${props.size}px`,
  minWidth: `${props.size}px`,
}));
</script>

<style scoped>
.image-thumbnail {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
  background: color-mix(in srgb, var(--card-bg, #fff) 85%, #d6e4f5 15%);
  color: #5c6f85;
  border: 1px solid color-mix(in srgb, var(--border-color, #d6e1ee) 80%, #b9cbdd 20%);
  font-size: 0.85rem;
  font-weight: 700;
  flex-shrink: 0;
}

.image-thumbnail--rounded {
  border-radius: 999px;
}

.image-thumbnail--square {
  border-radius: 10px;
}

.image-thumbnail img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
</style>
