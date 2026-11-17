import { describe, expect, it } from 'vitest';

import type { Workflow } from '@/types/generated';

import { buildStep } from 'test/factories/step';

import {
  aggregatePayload,
  draftStep,
  pinAll,
  snapshotOf,
  withDependency,
  withoutDependency,
  withoutStep,
  withPositions,
} from './builderDraft';
import { dataFlowKey } from './useWorkflowIssues';

const workflow = {
  id: 3,
  name: 'Release',
  description: null,
  runnerId: null,
  inheritAllProjectResources: false,
  baseToolIds: [],
  baseSkillIds: [],
  baseMCPServerIds: [],
  baseAssetIds: [],
  baseRepositoryIds: [],
  baseConfigItemIds: [],
} as unknown as Workflow;

const chain = () => [
  buildStep({ id: 1, position: 1 }),
  buildStep({ id: 2, position: 2, dependsOnStepIds: [1] }),
  buildStep({ id: 3, position: 3, dependsOnStepIds: [2] }),
];

describe('canvas position in the draft', () => {
  it('a new draft step has no position', () => {
    expect(draftStep([], 'A').canvasPosition).toBeNull();
  });

  it('the payload sends each step position unchanged, and null for auto-layout', () => {
    const steps = [buildStep({ id: 1, canvasPosition: { x: 10, y: -20 } }), buildStep({ id: 2, position: 2 })];
    const payload = aggregatePayload(workflow, steps);
    expect(payload.steps.map((s) => s.canvasPosition)).toEqual([{ x: 10, y: -20 }, null]);
  });

  it('the payload sends whole numbers', () => {
    const payload = aggregatePayload(workflow, [buildStep({ canvasPosition: { x: -0.5, y: 10.6 } })]);
    expect(payload.steps[0].canvasPosition).toEqual({ x: -0, y: 11 });
  });

  it('moving a step changes the snapshot but not the data-flow key', () => {
    const steps = chain();
    const moved = withPositions(steps, new Map([[2, { x: 5, y: 6 }]]));
    expect(snapshotOf(workflow, moved)).not.toBe(snapshotOf(workflow, steps));
    expect(dataFlowKey(workflow, moved)).toBe(dataFlowKey(workflow, steps));
  });
});

describe('withDependency', () => {
  it('adds the dependency', () => {
    const next = withDependency(chain(), 3, 1);
    expect(next?.find((s) => s.id === 3)?.dependsOnStepIds).toEqual([2, 1]);
  });

  it('refuses itself, an existing dependency and a cycle', () => {
    expect(withDependency(chain(), 2, 2)).toBeNull();
    expect(withDependency(chain(), 2, 1)).toBeNull();
    expect(withDependency(chain(), 1, 3)).toBeNull();
  });

  it('keeps the identity of the other steps', () => {
    const steps = chain();
    const next = withDependency(steps, 3, 1) ?? [];
    expect(next[0]).toBe(steps[0]);
    expect(next[1]).toBe(steps[1]);
  });
});

describe('withoutDependency', () => {
  it('removes the dependency and keeps the other steps', () => {
    const steps = chain();
    const next = withoutDependency(steps, 3, 2);
    expect(next[2].dependsOnStepIds).toEqual([]);
    expect(next[0]).toBe(steps[0]);
    expect(next[1]).toBe(steps[1]);
  });
});

describe('withoutStep', () => {
  it('drops the step and every dependency on it', () => {
    const next = withoutStep(chain(), 2);
    expect(next.map((s) => s.id)).toEqual([1, 3]);
    expect(next[1].dependsOnStepIds).toEqual([]);
  });
});

describe('withPositions', () => {
  it('sets positions and keeps the identity of steps that did not move', () => {
    const steps = [buildStep({ id: 1, canvasPosition: { x: 1, y: 1 } }), buildStep({ id: 2, position: 2 })];
    const next = withPositions(
      steps,
      new Map([
        [1, { x: 1, y: 1 }],
        [2, { x: 7, y: 8 }],
      ]),
    );
    expect(next[0]).toBe(steps[0]);
    expect(next[1].canvasPosition).toEqual({ x: 7, y: 8 });
  });
});

describe('pinAll', () => {
  it('pins steps without a position and leaves stored positions alone', () => {
    const steps = [buildStep({ id: 1, canvasPosition: { x: 1, y: 1 } }), buildStep({ id: 2, position: 2 })];
    const next = pinAll(
      steps,
      new Map([
        [1, { x: 99, y: 99 }],
        [2, { x: 7, y: 8 }],
      ]),
    );
    expect(next[0]).toBe(steps[0]);
    expect(next[1].canvasPosition).toEqual({ x: 7, y: 8 });
  });
});
