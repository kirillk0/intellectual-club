<template>
  <div class="stack">
    <div class="knowledge-block-details-title">Details</div>
    <div class="stack">
      <div class="knowledge-block-section-header">
        <div class="stack knowledge-block-section-title">
          <strong>Image</strong>
          <div class="muted knowledge-block-section-note">Used in selectors and catalogs.</div>
        </div>
        <div class="flex knowledge-block-image-actions">
          <button type="button" :disabled="isNew || saving" @click="triggerImageUpload">Upload</button>
          <button type="button" class="danger" :disabled="!image || saving" @click="removeImage">Remove</button>
        </div>
      </div>

      <input
        ref="imageInput"
        type="file"
        accept="image/*"
        class="knowledge-block-hidden-input"
        @change="handleImageSelected"
      />

      <div v-if="image" class="row knowledge-block-image-row">
        <ImageThumbnail :image="image" :label="name" :size="56" />
        <div class="stack knowledge-block-image-meta">
          <div class="knowledge-block-image-name">{{ image.filename }}</div>
          <div class="muted knowledge-block-section-note">{{ image.mime_type }}</div>
          <div class="muted knowledge-block-section-note">{{ formatFileBytes(image.size_bytes) }}</div>
        </div>
      </div>
      <div v-else class="muted">No image uploaded.</div>
      <div v-if="isNew" class="muted knowledge-block-section-note">Save the block before uploading an image.</div>
    </div>

    <div class="muted">External ID</div>
    <div class="knowledge-block-mono">{{ externalId || generatedOnSaveLabel }}</div>
    <div class="muted knowledge-block-details-label">Token estimate</div>
    <div>{{ tokenCount ?? calculatedOnSaveLabel }}</div>
  </div>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue';

import { getApiErrorMessage } from '@/api/client';
import { deleteKnowledgeBlockImage, uploadKnowledgeBlockImage } from '@/api/images';
import ImageThumbnail from '@/components/ImageThumbnail.vue';
import { translate } from '@/i18n';
import type { ImageAsset } from '@/types/api';
import { formatFileBytes } from '@/utils/fileSize';

const props = defineProps<{
  image: ImageAsset | null;
  name: string;
  isNew: boolean;
  saving: boolean;
  blockId: number | undefined;
  externalId: string | null;
  tokenCount: number | null;
}>();

const emit = defineEmits<{
  (e: 'update:image', value: ImageAsset | null): void;
}>();

const imageInput = ref<HTMLInputElement | null>(null);
const generatedOnSaveLabel = computed(() => translate('(generated on save)'));
const calculatedOnSaveLabel = computed(() => translate('(calculated on save)'));

const triggerImageUpload = () => imageInput.value?.click();

const handleImageSelected = async (event: Event) => {
  const target = event.target as HTMLInputElement | null;
  const file = target?.files?.[0];
  if (target) target.value = '';
  if (!file || props.isNew || props.blockId == null) return;

  try {
    const response = await uploadKnowledgeBlockImage(props.blockId, file);
    emit('update:image', response.image);
  } catch (error) {
    console.error(error);
    alert(getApiErrorMessage(error, 'Failed to upload image.'));
  }
};

const removeImage = async () => {
  if (!props.image || props.isNew || props.blockId == null) return;
  if (!window.confirm('Remove image?')) return;

  try {
    const response = await deleteKnowledgeBlockImage(props.blockId);
    emit('update:image', response.image);
  } catch (error) {
    console.error(error);
    alert('Failed to remove image.');
  }
};
</script>

<style scoped>
.knowledge-block-details-title {
  font-weight: 700;
}

.knowledge-block-section-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 10px;
}

.knowledge-block-section-title {
  gap: 2px;
}

.knowledge-block-section-note {
  font-size: 0.85rem;
}

.knowledge-block-image-actions {
  gap: 8px;
}

.knowledge-block-hidden-input {
  display: none;
}

.knowledge-block-image-row {
  align-items: center;
  gap: 12px;
}

.knowledge-block-image-meta {
  gap: 2px;
  min-width: 0;
}

.knowledge-block-image-name {
  font-weight: 600;
  overflow: hidden;
  text-overflow: ellipsis;
}

.knowledge-block-mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px;
}

.knowledge-block-details-label {
  margin-top: 6px;
}
</style>
