import { computed, type ComputedRef, type Ref } from 'vue';
import { getRecordset } from './recordsets';

type MaybeRef<T> = Ref<T> | ComputedRef<T>;

export function useCrudRecordsetNavigation(params: {
  recordsetKey: MaybeRef<string | undefined | null>;
  currentId: MaybeRef<number | undefined | null>;
  isNew: MaybeRef<boolean>;
  navigate: (id: number) => void;
}) {
  const ids = computed<number[]>(() => getRecordset(params.recordsetKey.value)?.ids ?? []);

  const currentIndex = computed(() => ids.value.findIndex((id) => id === params.currentId.value));

  const hasValidRecordset = computed(() => {
    if (!params.recordsetKey.value) return false;
    if (!ids.value.length) return params.isNew.value;
    if (params.isNew.value) return true;
    return currentIndex.value >= 0;
  });

  const totalCount = computed(() => {
    if (!hasValidRecordset.value) return 1;
    const base = ids.value.length;
    return base + (currentIndex.value === -1 && params.isNew.value ? 1 : 0);
  });

  const positionNumber = computed(() => {
    if (!hasValidRecordset.value) return 1;
    if (currentIndex.value >= 0) return currentIndex.value + 1;
    if (params.isNew.value) return ids.value.length + 1;
    return 1;
  });

  const navDisabled = computed(() => !hasValidRecordset.value || totalCount.value <= 1);

  const goPrev = () => {
    if (navDisabled.value) return;
    if (!ids.value.length) return;
    const idx = currentIndex.value;
    const prev = idx > 0 ? ids.value[idx - 1] : ids.value[ids.value.length - 1];
    params.navigate(prev);
  };

  const goNext = () => {
    if (navDisabled.value) return;
    if (!ids.value.length) return;
    const idx = currentIndex.value;
    const next = idx >= 0 && idx < ids.value.length - 1 ? ids.value[idx + 1] : ids.value[0];
    params.navigate(next);
  };

  return { ids, currentIndex, totalCount, positionNumber, navDisabled, goPrev, goNext };
}

