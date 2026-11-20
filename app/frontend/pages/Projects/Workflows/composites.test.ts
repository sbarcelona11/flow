import { describe, expect, it } from 'vitest';

import type { Step } from '@/types/generated';
import { buildCompositeBlock } from 'test/factories/moduleBlock';
import { buildStep } from 'test/factories/step';

import {
  blockLabel,
  frameNodeId,
  groupNodeId,
  instanceOfNode,
  instancesOf,
  newerVersion,
  nodeIdOf,
  rerouteEdges,
  rewriteKeys,
  summarizeGroup,
} from './composites';

const INSTANCE = '11111111-1111-4111-8111-111111111111';
const member = (id: number, node: string, patch: Partial<Step> = {}) =>
  buildStep({ id, position: id, composite: { ref: 'local/invoice-flow@1', instance: INSTANCE, node }, ...patch });

const steps = [
  buildStep({ id: 1, position: 1 }),
  member(2, 'summarise', { dependsOnStepIds: [1], budgetCents: 40 }),
  member(3, 'send_invoice', { kind: 'action', dependsOnStepIds: [2], budgetCents: 25 }),
  buildStep({ id: 4, position: 4, dependsOnStepIds: [3] }),
];

const edge = (source: string, target: string) => ({ id: `dep:${source}->${target}`, source, target });

describe('grouping steps by instance', () => {
  it('lists the steps of each instance and the node that draws a step', () => {
    expect([...instancesOf(steps).keys()]).toEqual([INSTANCE]);
    expect(
      instancesOf(steps)
        .get(INSTANCE)
        ?.map((s) => s.id),
    ).toEqual([2, 3]);
    expect(nodeIdOf(steps[1], new Set())).toBe(groupNodeId(INSTANCE));
    expect(nodeIdOf(steps[1], new Set([INSTANCE]))).toBe('2');
    expect(nodeIdOf(steps[0], new Set())).toBe('1');
  });

  it('reads the instance back from a group or frame node id, and none from a step node', () => {
    expect(instanceOfNode(groupNodeId(INSTANCE))).toBe(INSTANCE);
    expect(instanceOfNode(frameNodeId(INSTANCE))).toBe(INSTANCE);
    expect(instanceOfNode('7')).toBeNull();
  });
});

describe('rerouteEdges', () => {
  const edges = [edge('1', '2'), edge('2', '3'), edge('3', '4')];

  it('draws edges into and out of a collapsed group to the group and drops the ones inside it', () => {
    const routed = rerouteEdges(edges, steps, new Set());

    expect(routed.map((e) => [e.source, e.target])).toEqual([
      ['1', groupNodeId(INSTANCE)],
      [groupNodeId(INSTANCE), '4'],
    ]);
    expect(routed.every((e) => e.id.startsWith('grp:'))).toBe(true);
  });

  it('keeps one edge where several steps of a group are joined to the same node', () => {
    const routed = rerouteEdges([edge('1', '2'), edge('1', '3')], steps, new Set());

    expect(routed).toHaveLength(1);
  });

  it('leaves every edge alone while the group is expanded', () => {
    expect(rerouteEdges(edges, steps, new Set([INSTANCE]))).toEqual(edges);
  });
});

describe('rewriteKeys', () => {
  it('replaces the keys of output and step tokens, in nested strings too, and no other text', () => {
    const keys = new Map([['new-1', 'new-7']]);

    expect(
      rewriteKeys(
        { body: ['{{output:new-1:a.json}} and {{step:new-1}}', '{{output:new-2:b.json}}'], n: 3, note: 'new-1' },
        keys,
      ),
    ).toEqual({ body: ['{{output:new-7:a.json}} and {{step:new-7}}', '{{output:new-2:b.json}}'], n: 3, note: 'new-1' });
  });
});

describe('summarizeGroup', () => {
  const block = buildCompositeBlock();

  it('adds the caps of the inner steps and names the ports with their state', () => {
    const summary = summarizeGroup(
      [member(2, 'summarise', { budgetCents: 40 }), member(3, 'send_invoice', { kind: 'action', budgetCents: 25 })],
      [block],
    );

    expect(summary.label).toBe('Invoice flow');
    expect(summary.capCents).toBe(65);
    expect(summary.ports.out).toEqual([{ name: 'sent', type: 'string', connected: null }]);
    // body is not set, so the invoice port is not connected
    expect(summary.ports.in).toEqual([{ name: 'invoice', type: 'string', connected: false }]);
  });

  it('calls a port connected once the argument it feeds has a value', () => {
    const summary = summarizeGroup(
      [member(3, 'send_invoice', { kind: 'action', kindConfig: { arguments: { body: '{{output:1:rows.json}}' } } })],
      [block],
    );

    expect(summary.ports.in[0].connected).toBe(true);
  });

  it('has no cap when no inner step has one, and ignores the cap of a step that cannot carry one', () => {
    expect(summarizeGroup([member(2, 'summarise')], [block]).capCents).toBeNull();
    expect(summarizeGroup([member(2, 'approve', { kind: 'approval', budgetCents: 10 })], [block]).capCents).toBeNull();
  });

  it('still names a group whose block is no longer listed, and says nothing about its ports', () => {
    const summary = summarizeGroup([member(2, 'summarise')], []);

    expect(summary.known).toBe(false);
    expect(summary.label).toBe('invoice-flow');
    expect(summary.ports).toEqual({ in: [], out: [] });
  });
});

describe('versions and labels', () => {
  it('reports a higher valid composite version of the same block, and only that', () => {
    const v2 = buildCompositeBlock({ key: 'local/invoice-flow@2' });
    const other = buildCompositeBlock({ key: 'local/other@3' });
    const broken = buildCompositeBlock({ key: 'local/invoice-flow@5', status: 'invalid' });

    expect(newerVersion('local/invoice-flow@1', [v2, other, broken])).toBe(2);
    expect(newerVersion('local/invoice-flow@2', [v2])).toBeNull();
  });

  it('writes a label as one plain line', () => {
    const odd = buildCompositeBlock({ label: 'Pay\n‮evil <b>x</b>' });

    expect(blockLabel(odd.key, [odd])).toBe('Pay evil <b>x</b>');
  });
});
