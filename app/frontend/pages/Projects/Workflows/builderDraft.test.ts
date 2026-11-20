import { describe, expect, it } from 'vitest';

import type { Workflow } from '@/types/generated';
import { buildStep } from 'test/factories/step';

import {
  aggregatePayload,
  draftCompositeSteps,
  draftStep,
  draftSubStep,
  pinAll,
  snapshotOf,
  ungroup,
  withDependency,
  withoutDependency,
  withoutStep,
  withPositions,
  withProvenance,
} from './builderDraft';
import type { Expansion } from './composites';
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

describe('budget caps in the draft', () => {
  it('sends the step and workflow caps as integer cents, null when none', () => {
    const payload = aggregatePayload({ ...workflow, budgetCents: 500 }, [
      buildStep({ id: 1, kind: 'agent', budgetCents: 150 }),
      buildStep({ id: 2, position: 2, kind: 'action', budgetCents: null }),
    ]);
    expect(payload.budgetCents).toBe(500);
    expect(payload.steps.map((s) => s.budgetCents)).toEqual([150, null]);
  });

  it('never sends NaN, a fraction or an out-of-range value, and no cap for control steps', () => {
    const payload = aggregatePayload({ ...workflow, budgetCents: NaN }, [
      buildStep({ id: 1, budgetCents: 150.4 }),
      buildStep({ id: 2, position: 2, budgetCents: 2_000_000 }),
      buildStep({ id: 3, position: 3, kind: 'approval', budgetCents: 100 }),
    ]);
    expect(payload.budgetCents).toBeNull();
    expect(payload.steps.map((s) => s.budgetCents)).toEqual([150, null, null]);
  });

  it('editing a cap changes the snapshot and the data-flow key', () => {
    const steps = chain();
    const capped = steps.map((s) => (s.id === 2 ? { ...s, budgetCents: 100 } : s));
    expect(snapshotOf(workflow, capped)).not.toBe(snapshotOf(workflow, steps));
    expect(dataFlowKey(workflow, capped)).not.toBe(dataFlowKey(workflow, steps));
    expect(snapshotOf({ ...workflow, budgetCents: 100 }, steps)).not.toBe(snapshotOf(workflow, steps));
    expect(dataFlowKey({ ...workflow, budgetCents: 100 }, steps)).not.toBe(dataFlowKey(workflow, steps));
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

  it('removes every argument that reads an output of the removed step, nested or inline, and no other', () => {
    const consumer = buildStep({
      id: 3,
      position: 3,
      dependsOnStepIds: [1, 2],
      kind: 'action',
      kindConfig: {
        arguments: {
          whole: '{{output:1:rows.json}}',
          inline: 'see {{output:1:rows.json}} above',
          nested: { list: ['x', '{{output:1:rows.json}}'] },
          other: '{{output:2:rows.json}}',
          plain: 'text',
        },
      },
    });
    const next = withoutStep([buildStep({ id: 1 }), buildStep({ id: 2, position: 2 }), consumer], 1);
    expect(next[1].kindConfig.arguments).toEqual({ other: '{{output:2:rows.json}}', plain: 'text' });
    expect(next[1].dependsOnStepIds).toEqual([2]);
  });

  it('matches an unsaved step by its draft key', () => {
    const consumer = buildStep({
      id: -2,
      kind: 'action',
      kindConfig: { arguments: { a: '{{output:new-1:rows.json}}' } },
    });
    expect(withoutStep([buildStep({ id: -1 }), consumer], -1)[0].kindConfig.arguments).toEqual({});
  });
});

describe('dataFlowKey and arguments', () => {
  it('changes when a binding is written or removed, even with the dependency already present', () => {
    const steps = [
      buildStep({ id: 1, kind: 'action' }),
      buildStep({ id: 2, position: 2, kind: 'action', dependsOnStepIds: [1], kindConfig: { arguments: {} } }),
    ];
    const bound = steps.map((s) =>
      s.id === 2 ? { ...s, kindConfig: { arguments: { q: '{{output:1:rows.json}}' } } } : s,
    );
    expect(dataFlowKey(workflow, bound)).not.toBe(dataFlowKey(workflow, steps));
    const unbound = bound.map((s) => (s.id === 2 ? { ...s, kindConfig: { arguments: {} } } : s));
    expect(dataFlowKey(workflow, unbound)).toBe(dataFlowKey(workflow, steps));
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

  it('the payload puts whole numbers on the wire', () => {
    const payload = aggregatePayload(workflow, [buildStep({ canvasPosition: { x: -0.5, y: 10.6 } })]);
    expect(JSON.parse(JSON.stringify(payload.steps[0].canvasPosition))).toEqual({ x: 0, y: 11 });
  });

  it('keeps stored and pinned positions inside the bound the server accepts', () => {
    const steps = [buildStep({ id: 1 }), buildStep({ id: 2, position: 2 })];
    const far = new Map([
      [1, { x: 250_000, y: -250_000 }],
      [2, { x: 5, y: 6 }],
    ]);
    expect(withPositions(steps, far)[0].canvasPosition).toEqual({ x: 100_000, y: -100_000 });
    expect(pinAll(steps, far)[0].canvasPosition).toEqual({ x: 100_000, y: -100_000 });
  });
});

describe('what the data-flow check re-reads', () => {
  it('changes when a step is pinned to another runtime, which the budget warning depends on', () => {
    const steps = [buildStep({ id: 1, kind: 'agent', budgetCents: 100, requiredAgentRuntime: 'claude_code' })];
    const pinned = [{ ...steps[0], requiredAgentRuntime: 'codex' }];

    expect(dataFlowKey(workflow, pinned)).not.toBe(dataFlowKey(workflow, steps));
  });
});

describe('composite blocks in the draft', () => {
  const INSTANCE = '11111111-1111-4111-8111-111111111111';
  const expansion = (): Expansion => ({
    instance: INSTANCE,
    warnings: [],
    unbound: [],
    steps: [
      {
        key: 'new-1',
        name: 'Summarise',
        kind: 'agent',
        instructions: 'Summarise {{output:7:invoice.json}}',
        depends_on_step_ids: [7],
        canvas_position: { x: 0, y: 0 },
        composite: { ref: 'local/flow@1', instance: INSTANCE, node: 'summarise' },
        budget_cents: 40,
        sub_steps: [{ name: 'Check totals', instructions: 'see {{step:new-1}}' }],
        output_asset_specs: [{ name: 'summary.md', asset_type: 'file', required: true }],
      },
      {
        key: 'new-2',
        name: 'Send',
        kind: 'action',
        kind_config: {
          target: 'rest_operation',
          api_operation_id: 9,
          effect: 'send',
          output_name: 'sent.json',
          arguments: { body: '{{output:new-1:summary.md}}', some_arg: 'x' },
        },
        depends_on_step_ids: ['new-1'],
        canvas_position: { x: 320, y: 0 },
        composite: { ref: 'local/flow@1', instance: INSTANCE, node: 'send' },
      },
    ],
  });
  const existing = [
    buildStep({ id: -1, position: 1 }),
    buildStep({ id: -2, position: 2, subSteps: [{ ...draftSubStep([], buildStep(), 'x'), id: -3 }] }),
  ];

  it('gives the steps draft ids that collide with nothing in the draft, sub-steps included', () => {
    const added = draftCompositeSteps(existing, expansion());

    expect(added.map((s) => s.id)).toEqual([-4, -5]);
    expect(added[0].subSteps[0]).toMatchObject({ id: -6, stepId: -4, name: 'Check totals', position: 1 });
    expect(added.map((s) => s.position)).toEqual([3, 4]);
  });

  it('rewrites keys in dependencies and tokens, and keeps a binding to a step already in the draft', () => {
    const [summarise, send] = draftCompositeSteps(existing, expansion());

    expect(send.dependsOnStepIds).toEqual([summarise.id]);
    expect(send.kindConfig.arguments).toEqual({ body: '{{output:new-4:summary.md}}', some_arg: 'x' });
    expect(summarise.instructions).toBe('Summarise {{output:7:invoice.json}}');
    expect(summarise.dependsOnStepIds).toEqual([7]);
    expect(summarise.subSteps[0].instructions).toBe('see {{step:new-4}}');
  });

  it('reads the server shape into a draft step and keeps the provenance', () => {
    const [summarise, send] = draftCompositeSteps(existing, expansion());

    expect(send.kindConfig).toMatchObject({
      target: 'rest_operation',
      apiOperationId: 9,
      effect: 'send',
      outputName: 'sent.json',
    });
    expect(Object.keys(send.kindConfig.arguments ?? {})).toEqual(['body', 'some_arg']);
    expect(summarise.outputAssetSpecs).toEqual([{ name: 'summary.md', assetType: 'file', required: true }]);
    expect(summarise.budgetCents).toBe(40);
    expect(send.composite).toEqual({ ref: 'local/flow@1', instance: INSTANCE, node: 'send' });
  });

  it('places the steps from an origin, keeping the layout the server gave, or leaves them unplaced', () => {
    expect(draftCompositeSteps(existing, expansion()).map((s) => s.canvasPosition)).toEqual([null, null]);
    expect(draftCompositeSteps(existing, expansion(), { x: 500.4, y: 40 }).map((s) => s.canvasPosition)).toEqual([
      { x: 500, y: 40 },
      { x: 820, y: 40 },
    ]);
  });

  it('ungroup clears the provenance of one instance and changes nothing else', () => {
    const added = draftCompositeSteps(existing, expansion());
    const other = buildStep({
      id: 90,
      composite: { ref: 'local/x@1', instance: '22222222-2222-4222-8222-222222222222', node: 'a' },
    });
    const steps = [...added, other];

    const result = ungroup(steps, INSTANCE);

    expect(result.map((s) => s.composite?.node ?? null)).toEqual([null, null, 'a']);
    expect(result.map((s) => ({ ...s, composite: null }))).toEqual(steps.map((s) => ({ ...s, composite: null })));
  });

  it('marks existing steps as an instance without creating or changing anything else', () => {
    const result = withProvenance(
      chain(),
      'local/flow@1',
      'u-1',
      new Map([
        [2, 'two'],
        [3, 'three'],
      ]),
    );

    expect(result.map((s) => s.composite?.node ?? null)).toEqual([null, 'two', 'three']);
    expect(result.map((s) => s.id)).toEqual([1, 2, 3]);
  });

  it('lets go of the leftover members of an instance that was only partly picked', () => {
    const grouped = withProvenance(
      chain(),
      'local/old@1',
      'u-old',
      new Map([
        [2, 'a'],
        [3, 'b'],
      ]),
    );

    const result = withProvenance(grouped, 'local/new@1', 'u-new', new Map([[2, 'x']]));

    expect(result.map((s) => s.composite)).toEqual([null, { ref: 'local/new@1', instance: 'u-new', node: 'x' }, null]);
  });

  it('sends the provenance with a save, and an explicit null once it is cleared', () => {
    const grouped = withProvenance(chain(), 'local/flow@1', 'u-1', new Map([[2, 'two']]));

    expect(aggregatePayload(workflow, grouped).steps.map((s) => s.composite)).toEqual([
      null,
      { ref: 'local/flow@1', instance: 'u-1', node: 'two' },
      null,
    ]);
    expect(aggregatePayload(workflow, ungroup(grouped, 'u-1')).steps.map((s) => s.composite)).toEqual([
      null,
      null,
      null,
    ]);
  });
});
