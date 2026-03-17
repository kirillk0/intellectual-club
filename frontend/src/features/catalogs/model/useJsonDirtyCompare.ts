import { computed } from 'vue';
import { stableStringify } from '@/utils/stableJson';

export function useJsonDirtyCompare<T>(current: () => T, base: () => T) {
  return computed(() => stableStringify(current()) !== stableStringify(base()));
}

