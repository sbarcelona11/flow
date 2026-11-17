import { describe, expect, it } from 'vitest';

import { buildStep } from 'test/factories/step';

import { dependencyRefusal, eligibleDependencies, refusalMessage } from './connections';

const chain = [
  buildStep({ id: 1, name: 'A', position: 1 }),
  buildStep({ id: 2, name: 'B', position: 2, dependsOnStepIds: [1] }),
  buildStep({ id: 3, name: 'C', position: 3, dependsOnStepIds: [2] }),
  buildStep({ id: 4, name: 'D', position: 4 }),
];

describe('dependencyRefusal', () => {
  it('refuses a step running after itself, after what it already runs after, and a loop', () => {
    expect(dependencyRefusal(chain, 1, 1)).toBe('self');
    expect(dependencyRefusal(chain, 2, 1)).toBe('exists');
    expect(dependencyRefusal(chain, 1, 3)).toBe('cycle');
  });

  it('allows any other pair', () => {
    expect(dependencyRefusal(chain, 4, 3)).toBeNull();
    expect(dependencyRefusal(chain, 3, 1)).toBeNull();
  });
});

describe('eligibleDependencies', () => {
  it('lists the steps that could come first, never a step downstream', () => {
    expect(eligibleDependencies(chain, 1).map((s) => s.name)).toEqual(['D']);
    expect(eligibleDependencies(chain, 4).map((s) => s.name)).toEqual(['A', 'B', 'C']);
  });
});

describe('refusalMessage', () => {
  it('says why in plain words', () => {
    expect(refusalMessage('self', 'A', 'A')).toBe('A cannot run after itself');
    expect(refusalMessage('cycle', 'A', 'C')).toContain('loop back on itself');
  });
});
