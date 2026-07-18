import { afterEach, describe, expect, it } from 'vitest';

import { setPreferredLocale } from '@/i18n';
import { formatEstimatedTokensCompact } from '@/utils/tokens';

describe('token formatting', () => {
  afterEach(() => setPreferredLocale(null));

  it('uses a localized compact token label', () => {
    setPreferredLocale('en');
    expect(formatEstimatedTokensCompact(1223)).toBe('~1,223 tok.');

    setPreferredLocale('ru');
    expect(formatEstimatedTokensCompact(1223)).toBe('~1 223 т.');
  });
});
