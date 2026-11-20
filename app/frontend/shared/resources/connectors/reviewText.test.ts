import { describe, expect, it } from 'vitest';

import { plainLine, schemaSummary } from './reviewText';

describe('plainLine', () => {
  it('makes one line without newlines, control or direction-changing characters', () => {
    expect(plainLine('a\nb\r\nc\td‮evil⁦x​')).toBe('a b c devilx');
  });

  it('neutralises arrows that could pose as a secret line', () => {
    for (const arrow of ['→', '⇒', '➔', '⟶', '->', '=>', '-->', '➜', '↦']) {
      expect(plainLine(`STRIPE_KEY ${arrow} good.com`)).not.toMatch(/[→⇒➔⟶➜↦>]/);
    }
  });

  it('caps the length', () => {
    const line = plainLine('x'.repeat(1000), 50);
    expect(line).toHaveLength(50);
    expect(line.endsWith('…')).toBe(true);
  });
});

describe('schemaSummary', () => {
  it('lists each argument with its type and whether it is required', () => {
    const schema = {
      type: 'object',
      properties: {
        path: { type: 'object', required: ['id'], properties: { id: { type: 'string' } } },
        query: { type: 'object', properties: { limit: { type: 'integer' } } },
      },
    };

    expect(schemaSummary(schema)).toEqual(['path.id: string, required', 'query.limit: integer']);
    expect(schemaSummary(null)).toEqual([]);
  });
});
