import type { Step } from '@/types/generated';

export const NODE_WIDTH = 240;
export const NODE_HEIGHT = 96;
export const LAYER_GAP = 120;
export const ROW_GAP = 32;

const COLUMN = NODE_WIDTH + LAYER_GAP;
const ROW = NODE_HEIGHT + ROW_GAP;

export interface Point {
  x: number;
  y: number;
}

/** `canvasPosition` is the stored position (`null`: auto-layout). */
export type LayoutStep = Pick<Step, 'id' | 'position' | 'dependsOnStepIds'> & { canvasPosition?: Point | null };

const byPosition = (a: LayoutStep, b: LayoutStep) => a.position - b.position || a.id - b.id;

/** Dependencies that exist and do not close a cycle; a cycle breaks at its lowest-position step. */
function acyclicDependencies(steps: LayoutStep[]): Map<number, number[]> {
  const ids = new Set(steps.map((s) => s.id));
  const sorted = [...steps].sort(byPosition);
  const dependents = new Map<number, number[]>(sorted.map((s) => [s.id, []]));
  for (const s of sorted) {
    for (const dep of s.dependsOnStepIds) if (ids.has(dep) && dep !== s.id) dependents.get(dep)?.push(s.id);
  }

  const kept = new Map<number, number[]>(sorted.map((s) => [s.id, []]));
  const state = new Map<number, 'open' | 'done'>();
  const visit = (id: number) => {
    state.set(id, 'open');
    for (const next of dependents.get(id) ?? []) {
      if (state.get(next) === 'open') continue;
      kept.get(next)?.push(id);
      if (!state.has(next)) visit(next);
    }
    state.set(id, 'done');
  };
  for (const s of sorted) if (!state.has(s.id)) visit(s.id);
  return kept;
}

function layerOf(steps: LayoutStep[], deps: Map<number, number[]>): Map<number, number> {
  const layers = new Map<number, number>();
  const depth = (id: number): number => {
    const known = layers.get(id);
    if (known !== undefined) return known;
    const value = Math.max(-1, ...(deps.get(id) ?? []).map(depth)) + 1;
    layers.set(id, value);
    return value;
  };
  for (const s of steps) depth(s.id);
  return layers;
}

/**
 * Layered left-to-right layout: longest-path layers over the dependencies, then two barycenter
 * sweeps to order each layer. Deterministic for the same input.
 */
export function autoLayout(steps: Pick<LayoutStep, 'id' | 'position' | 'dependsOnStepIds'>[]): Map<number, Point> {
  const sorted = [...steps].sort(byPosition);
  const deps = acyclicDependencies(sorted);
  const layerById = layerOf(sorted, deps);
  const layerCount = Math.max(-1, ...layerById.values()) + 1;

  const columns: number[][] = Array.from({ length: layerCount }, () => []);
  for (const s of sorted) columns[layerById.get(s.id) as number].push(s.id);

  const successors = new Map<number, number[]>(sorted.map((s) => [s.id, []]));
  for (const [id, list] of deps) for (const dep of list) successors.get(dep)?.push(id);

  const rank = new Map<number, number>();
  const rerank = (column: number[]) => column.forEach((id, i) => rank.set(id, i - (column.length - 1) / 2));
  columns.forEach(rerank);

  const sweep = (column: number[], neighbours: Map<number, number[]>) => {
    const score = new Map(
      column.map((id) => {
        const ranks = (neighbours.get(id) ?? []).map((n) => rank.get(n) as number);
        return [id, ranks.length ? ranks.reduce((a, b) => a + b, 0) / ranks.length : (rank.get(id) as number)];
      }),
    );
    column.sort((a, b) => (score.get(a) as number) - (score.get(b) as number));
    rerank(column);
  };
  for (let l = 1; l < layerCount; l++) sweep(columns[l], deps);
  for (let l = layerCount - 2; l >= 0; l--) sweep(columns[l], successors);

  const tallest = Math.max(0, ...columns.map((c) => c.length));
  const result = new Map<number, Point>();
  columns.forEach((column, layer) => {
    const offset = ((tallest - column.length) * ROW) / 2;
    column.forEach((id, row) => result.set(id, { x: layer * COLUMN, y: offset + row * ROW }));
  });
  return result;
}

/** The structure the canvas memoises its layout on: ids, dependencies and stored positions. */
export function layoutKey(steps: LayoutStep[]): string {
  return steps
    .map((s) => {
      const p = s.canvasPosition;
      return `${s.id}:${[...s.dependsOnStepIds].sort((a, b) => a - b).join(',')}:${p ? `${p.x},${p.y}` : ''}`;
    })
    .join('|');
}

/** Stored positions where present; the rest are laid out to the right of the right-most stored node. */
export function resolvePositions(steps: LayoutStep[]): Map<number, Point> {
  const stored = steps.filter((s) => s.canvasPosition);
  const autoSteps = steps.filter((s) => !s.canvasPosition);
  const auto = autoLayout(autoSteps);
  if (stored.length === 0) return auto;
  const result = new Map<number, Point>();

  const rightEdge = Math.max(...stored.map((s) => (s.canvasPosition as Point).x)) + COLUMN;
  const leftMost = Math.min(...autoSteps.map((s) => (auto.get(s.id) as Point).x));
  for (const s of steps) {
    if (s.canvasPosition) result.set(s.id, s.canvasPosition);
    else {
      const p = auto.get(s.id) as Point;
      result.set(s.id, { x: p.x - leftMost + rightEdge, y: p.y });
    }
  }
  return result;
}
