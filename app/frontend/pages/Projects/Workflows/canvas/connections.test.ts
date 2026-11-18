import { describe, expect, it } from 'vitest';

import { buildStep } from 'test/factories/step';

import { dependencyRefusal, dropMessage, eligibleDependencies, orientDrop, refusalMessage } from './connections';

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

describe('orientDrop', () => {
  it('makes the step a drag started on its out handle the dependency', () => {
    expect(orientDrop({ fromType: 'source', toType: 'target', fromId: 1, toId: 2 })).toEqual({
      stepId: 2,
      dependencyId: 1,
    });
  });

  it('makes the step a drag started on its in handle the one that runs after', () => {
    expect(orientDrop({ fromType: 'target', toType: 'source', fromId: 2, toId: 1 })).toEqual({
      stepId: 2,
      dependencyId: 1,
    });
  });

  it('has no direction for out to out or in to in', () => {
    expect(orientDrop({ fromType: 'source', toType: 'source', fromId: 1, toId: 2 })).toBeNull();
    expect(orientDrop({ fromType: 'target', toType: 'target', fromId: 1, toId: 2 })).toBeNull();
  });
});

describe('dropMessage', () => {
  it('names the actual reason, whichever handle the drag started on', () => {
    // C -> B -> A. Dragging from A's in handle to C's out handle would loop; B's in to A's out already exists.
    expect(dropMessage(chain, { fromType: 'target', toType: 'source', fromId: 1, toId: 3 })).toContain('loop back');
    expect(dropMessage(chain, { fromType: 'target', toType: 'source', fromId: 2, toId: 1 })).toBe(
      'B already runs after A',
    );
    expect(dropMessage(chain, { fromType: 'source', toType: 'target', fromId: 1, toId: 2 })).toBe(
      'B already runs after A',
    );
  });

  it('asks for an out handle on one side and an in handle on the other', () => {
    expect(dropMessage(chain, { fromType: 'source', toType: 'source', fromId: 1, toId: 4 })).toBe(
      'Connect a step’s out handle to another step’s in handle',
    );
  });

  it('has nothing to say about a drop that would be accepted', () => {
    expect(dropMessage(chain, { fromType: 'target', toType: 'source', fromId: 4, toId: 3 })).toBeNull();
  });
});
