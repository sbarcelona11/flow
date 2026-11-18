import { describe, expect, it } from 'vitest';

import { capCentsFromInput, formatCapCents, sanitizeCapCents } from './budgetCap';

describe('capCentsFromInput', () => {
  it.each([
    [1.15, 115],
    [0.29, 29],
    [19.99, 1999],
    [10000, 1_000_000],
    [0.01, 1],
    [1.5, 150],
  ])('turns %s dollars into %s cents without drift', (dollars, cents) => {
    expect(capCentsFromInput(dollars)).toBe(cents);
  });

  it('treats an empty input as no cap', () => {
    expect(capCentsFromInput('')).toBeNull();
  });

  it('refuses out-of-range, partial and non-finite input', () => {
    for (const bad of [0, -1, 0.001, 10000.01, 20000, NaN, Infinity, '1.', 'abc', '-']) {
      expect(capCentsFromInput(bad)).toBeUndefined();
    }
  });
});

describe('sanitizeCapCents', () => {
  it('keeps integer cents in range and sends null for anything else', () => {
    expect(sanitizeCapCents(150)).toBe(150);
    expect(sanitizeCapCents(1_000_000)).toBe(1_000_000);
    expect(sanitizeCapCents(null)).toBeNull();
    expect(sanitizeCapCents(undefined)).toBeNull();
    expect(sanitizeCapCents(NaN)).toBeNull();
    expect(sanitizeCapCents(0)).toBeNull();
    expect(sanitizeCapCents(1_000_001)).toBeNull();
    expect(sanitizeCapCents(150.4)).toBe(150);
  });
});

describe('formatCapCents', () => {
  it('shows exact dollars and cents, never abbreviated', () => {
    expect(formatCapCents(150)).toBe('$1.50');
    expect(formatCapCents(5)).toBe('$0.05');
    expect(formatCapCents(1999)).toBe('$19.99');
    expect(formatCapCents(1_000_000)).toBe('$10000.00');
  });
});
