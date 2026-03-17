import { ref } from 'vue';
import {
  fieldErrorsFromJsonApiErrors,
  formErrorsFromJsonApiErrors,
  getJsonApiErrors,
  type FieldErrors,
} from '@/api/jsonApi';

export function useFormErrors() {
  const formErrors = ref<string[]>([]);
  const fieldErrors = ref<FieldErrors>({});

  const clear = () => {
    formErrors.value = [];
    fieldErrors.value = {};
  };

  const clearField = (field: string) => {
    if (!fieldErrors.value[field]) return;
    const next: FieldErrors = { ...fieldErrors.value };
    delete next[field];
    fieldErrors.value = next;
  };

  const hasField = (field: string) => Boolean(fieldErrors.value[field]?.length);

  const messageFor = (field: string) => (fieldErrors.value[field] || []).join(' ');

  const setFromApiError = (error: unknown): boolean => {
    const errors = getJsonApiErrors(error);
    if (!errors) return false;
    formErrors.value = formErrorsFromJsonApiErrors(errors);
    fieldErrors.value = fieldErrorsFromJsonApiErrors(errors);
    return true;
  };

  return {
    formErrors,
    fieldErrors,
    clear,
    clearField,
    hasField,
    messageFor,
    setFromApiError,
  };
}
