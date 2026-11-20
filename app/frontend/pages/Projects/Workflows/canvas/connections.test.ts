import { describe, expect, it } from 'vitest';

import type { ModuleBlock, Step } from '@/types/generated';
import { buildCompositeBlock } from 'test/factories/moduleBlock';
import { buildStep } from 'test/factories/step';

import { withPortBinding } from '../actionArguments';

import {
  bindingOptions,
  bindingRefusalMessage,
  dependencyRefusal,
  dropMessage,
  eligibleDependencies,
  groupPortBindable,
  orientDrop,
  refusalMessage,
  withGroupPortBinding,
  withoutGroupPortBinding,
} from './connections';

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

describe('port binding', () => {
  const fetcher = { key: 'fetch', ports: { in: {}, out: { rows: 'list<row>', note: '' } } } as unknown as ModuleBlock;
  const action = (id: number, patch: Parameters<typeof buildStep>[0] = {}) =>
    buildStep({
      id,
      name: `S${id}`,
      position: id,
      kind: 'action',
      kindConfig: { block: 'fetch', target: 'mcp_tool' },
      outputAssetSpecs: [{ name: 'rows.json', assetType: 'file', required: true }],
      ...patch,
    });

  it('lists the out ports of every action step that could come first, without comparing types', () => {
    const steps = [action(1), action(2), action(3, { dependsOnStepIds: [2] })];
    expect(bindingOptions(steps, [fetcher], 2).map((o) => `${o.stepName}.${o.port}:${o.type}`)).toEqual([
      'S1.rows:list<row>',
    ]);
  });

  it('offers only ports the step declares as an output file', () => {
    const renamed = action(1, { outputAssetSpecs: [{ name: 'note.json', assetType: 'file', required: true }] });
    expect(bindingOptions([renamed, action(2)], [fetcher], 2).map((o) => o.port)).toEqual(['note']);
    expect(bindingOptions([action(1, { outputAssetSpecs: [] }), action(2)], [fetcher], 2)).toEqual([]);
  });

  it('skips steps that are not blocks, or that run after the target', () => {
    const steps = [buildStep({ id: 1, position: 1 }), action(2), action(3, { dependsOnStepIds: [2] })];
    expect(bindingOptions(steps, [fetcher], 2)).toEqual([]);
  });

  it('says why a binding was refused', () => {
    const wrapper = [action(1), action(2, { kindConfig: { block: 'fetch', target: 'wrapper' } })];
    expect(bindingRefusalMessage(wrapper, { from: 1, port: 'rows', to: 2, argument: 'a' })).toBe(
      'S2 is a Wrapper action and cannot read step outputs',
    );
    const loop = [action(1, { dependsOnStepIds: [2] }), action(2)];
    expect(bindingRefusalMessage(loop, { from: 1, port: 'rows', to: 2, argument: 'a' })).toMatch(/loop back/);
  });
});

describe('composite blocks', () => {
  const INSTANCE = '11111111-1111-4111-8111-111111111111';
  const block = buildCompositeBlock();
  const inner = (id: number, node: string, patch: Partial<Step> = {}) =>
    buildStep({ id, position: id, composite: { ref: block.key, instance: INSTANCE, node }, ...patch });
  const upstream = buildStep({ id: 1, position: 1, name: 'Upstream' });
  const sender = inner(3, 'send_invoice', {
    kind: 'action',
    name: 'Send invoice',
    kindConfig: { target: 'rest_operation', arguments: { body: '' } },
    outputAssetSpecs: [{ name: 'sent.json', assetType: 'file', required: true }],
  });
  const steps = [upstream, inner(2, 'summarise'), sender];
  const upstreamOut = { stepId: 1, stepName: 'Upstream', port: 'rows', type: 'list<row>' };

  it('offers a composite out port for the inner step it comes from, with the file it names', () => {
    const options = bindingOptions([sender, buildStep({ id: 9, position: 9 })], [block], 9);

    expect(options).toEqual([{ stepId: 3, stepName: 'Send invoice', port: 'sent', type: 'string', file: 'sent.json' }]);
  });

  it('writes the output file of the out port, not <port>.json, when it is bound', () => {
    const target = buildStep({
      id: 9,
      position: 9,
      kind: 'action',
      kindConfig: { target: 'rest_operation', arguments: {} },
    });
    const option = bindingOptions([sender, target], [block], 9)[0];

    const bound = withPortBinding([sender, target], {
      from: option.stepId,
      port: option.port,
      file: option.file,
      to: 9,
      argument: 'x',
    });

    expect(bound?.find((s) => s.id === 9)?.kindConfig.arguments).toEqual({ x: '{{output:3:sent.json}}' });
  });

  it('binds an in port by writing the argument the block names, in the inner step, and its dependency', () => {
    const result = withGroupPortBinding(steps, [block], INSTANCE, 'invoice', upstreamOut);

    const written = result?.find((s) => s.id === 3);
    expect(written?.kindConfig.arguments).toEqual({ body: '{{output:1:rows.json}}' });
    expect(written?.dependsOnStepIds).toEqual([1]);
    expect(groupPortBindable(steps, [block], INSTANCE, 'invoice')).toBe(true);
  });

  it('refuses a port with nothing to write to, and one whose binding any step refuses', () => {
    expect(withGroupPortBinding(steps, [block], INSTANCE, 'unknown', upstreamOut)).toBeNull();
    expect(groupPortBindable(steps, [block], INSTANCE, 'unknown')).toBe(false);
    const wrapper = steps.map((s) =>
      s.id === 3 ? { ...s, kindConfig: { ...s.kindConfig, target: 'wrapper' as const } } : s,
    );
    expect(withGroupPortBinding(wrapper, [block], INSTANCE, 'invoice', upstreamOut)).toBeNull();
  });

  it('clears the arguments of an in port and leaves the dependency', () => {
    const bound = withGroupPortBinding(steps, [block], INSTANCE, 'invoice', upstreamOut) as Step[];

    const result = withoutGroupPortBinding(bound, [block], INSTANCE, 'invoice');

    const cleared = result.find((s) => s.id === 3);
    expect(cleared?.kindConfig.arguments).toEqual({});
    expect(cleared?.dependsOnStepIds).toEqual([1]);
  });
});
