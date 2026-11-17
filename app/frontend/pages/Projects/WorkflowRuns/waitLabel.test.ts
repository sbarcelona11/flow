import { describe, expect, it } from 'vitest';

import { buildStepRun } from 'test/factories/stepRun';

import { formatWaitUntil, waitLabel } from './waitLabel';

describe('waitLabel', () => {
  it('names the time the wait resolved to', () => {
    const step = buildStepRun({ stepKind: 'wait', waitUntil: '2026-11-18T10:00:00Z' });

    expect(waitLabel(step)).toBe(`Waiting until ${formatWaitUntil('2026-11-18T10:00:00Z')}`);
  });

  it('says nothing before the wait has resolved its time', () => {
    const step = buildStepRun({ stepKind: 'wait', stepKindConfig: { untilContextKey: 'campaign.publish_at' } });

    expect(waitLabel(step)).toBeNull();
  });

  it('formats the time with the date and the minute', () => {
    expect(formatWaitUntil('2026-11-18T10:00:00Z', 'en-US', 'UTC')).toMatch(/^Nov 18, 2026, 10:00\sAM$/);
  });
});
