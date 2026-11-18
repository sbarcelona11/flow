import { describe, expect, it } from 'vitest';

import { autoLayout, freeSpot, layoutKey, resolvePositions } from './layout';

const node = (id: number, deps: number[] = [], position = id) => ({ id, position, dependsOnStepIds: deps });

describe('autoLayout', () => {
  it('lays a chain out left to right on one row', () => {
    const layout = autoLayout([node(1), node(2, [1]), node(3, [2])]);
    expect([1, 2, 3].map((id) => layout.get(id))).toEqual([
      { x: 0, y: 0 },
      { x: 360, y: 0 },
      { x: 720, y: 0 },
    ]);
  });

  it('puts the two branches of a diamond in one layer and centres the ends on them', () => {
    const layout = autoLayout([node(1), node(2, [1]), node(3, [1]), node(4, [2, 3])]);
    expect(layout.get(2)?.x).toBe(360);
    expect(layout.get(3)?.x).toBe(360);
    expect(layout.get(2)?.y).toBe(0);
    expect(layout.get(3)?.y).toBe(128);
    expect(layout.get(1)?.y).toBe(64);
    expect(layout.get(4)).toEqual({ x: 720, y: 64 });
  });

  it('stacks two roots in layer zero ordered by position', () => {
    const layout = autoLayout([node(5, [], 2), node(6, [], 1)]);
    expect(layout.get(6)).toEqual({ x: 0, y: 0 });
    expect(layout.get(5)).toEqual({ x: 0, y: 128 });
  });

  it('places a disconnected step in layer zero', () => {
    const layout = autoLayout([node(1), node(2, [1]), node(3)]);
    expect(layout.get(3)?.x).toBe(0);
    expect(layout.get(3)?.y).not.toBe(layout.get(1)?.y);
  });

  it('ignores a dependency on a missing step', () => {
    expect(autoLayout([node(1, [99])]).get(1)).toEqual({ x: 0, y: 0 });
  });

  it('breaks a cycle at the lowest position instead of hanging', () => {
    const layout = autoLayout([node(1, [2], 1), node(2, [1], 2)]);
    expect(layout.get(1)?.x).toBe(0);
    expect(layout.get(2)?.x).toBe(360);
  });

  it('is deterministic', () => {
    const steps = [node(1), node(2, [1]), node(3, [1]), node(4, [2, 3])];
    expect([...autoLayout(steps)]).toEqual([...autoLayout([...steps].reverse().reverse())]);
  });

  it('keeps a 200-node random DAG overlap-free with every edge going left to right', () => {
    let seed = 7;
    const random = () => {
      seed = (seed * 1664525 + 1013904223) % 4294967296;
      return seed / 4294967296;
    };
    const steps = Array.from({ length: 200 }, (_, i) => {
      const deps = Array.from({ length: i }, (_, j) => j + 1).filter(() => i > 0 && random() < 0.02);
      return node(i + 1, deps);
    });
    const layout = autoLayout(steps);
    const spots = new Set([...layout.values()].map((p) => `${p.x},${p.y}`));
    expect(spots.size).toBe(200);
    for (const s of steps) {
      for (const dep of s.dependsOnStepIds) expect(layout.get(dep)!.x).toBeLessThan(layout.get(s.id)!.x);
    }
  });
});

describe('layoutKey', () => {
  it('changes with dependencies and stored positions, not with their order', () => {
    const base = layoutKey([{ ...node(1), canvasPosition: null }, node(2, [1, 3]), node(3)]);
    expect(layoutKey([{ ...node(1), canvasPosition: null }, node(2, [3, 1]), node(3)])).toBe(base);
    expect(layoutKey([{ ...node(1), canvasPosition: null }, node(2, [1]), node(3)])).not.toBe(base);
    expect(layoutKey([{ ...node(1), canvasPosition: { x: 1, y: 2 } }, node(2, [1, 3]), node(3)])).not.toBe(base);
  });
});

describe('resolvePositions', () => {
  it('uses auto-layout when nothing is stored', () => {
    const steps = [node(1), node(2, [1])];
    expect(resolvePositions(steps)).toEqual(autoLayout(steps));
  });

  it('keeps stored positions and moves the others right of the right-most stored node', () => {
    const steps = [{ ...node(1), canvasPosition: { x: 500, y: 40 } }, node(2), node(3, [2])];
    const resolved = resolvePositions(steps);
    expect(resolved.get(1)).toEqual({ x: 500, y: 40 });
    expect(resolved.get(2)).toEqual({ x: 860, y: 0 });
    expect(resolved.get(3)).toEqual({ x: 1220, y: 0 });
  });
});

describe('freeSpot', () => {
  it('keeps a spot nothing occupies', () => {
    expect(freeSpot({ x: 360, y: 0 }, [{ x: 0, y: 0 }])).toEqual({ x: 360, y: 0 });
  });

  it('moves down a row at a time until a standard node would not overlap', () => {
    const occupied = [
      { x: 360, y: 0 },
      { x: 400, y: 128 },
    ];
    expect(freeSpot({ x: 360, y: 0 }, occupied)).toEqual({ x: 360, y: 256 });
  });
});
