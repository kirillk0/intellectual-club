import { afterEach, describe, expect, it } from 'vitest';

import { setPreferredLocale, translate } from '@/i18n';

describe('native agent management translations', () => {
  afterEach(() => setPreferredLocale(null));

  it('translates generic subchat settings and spawn relation labels', () => {
    setPreferredLocale('ru');

    expect(translate('Nested subchats limit')).toBe('Лимит вложенных сабчатов');
    expect(translate('Allow handoff in subchats')).toBe('Разрешить handoff в сабчатах');
    expect(translate('Spawn')).toBe('Спавн');
    expect(translate('Spawned from')).toBe('Спавн из');
    expect(translate('Spawned into')).toBe('Спавн в');
    expect(
      translate(
        'Start a linked subagent chat with the same bot and chat settings but no copied conversation history, and wait for it to finish.'
      )
    ).toContain('без копирования истории');
  });
});
