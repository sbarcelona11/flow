import { describe, expect, it } from 'vitest';

import type { ModuleBlock, Step } from '@/types/generated';
import { buildCompositeBlock } from 'test/factories/moduleBlock';

import { draftBlockStep, draftStep } from '../builderDraft';
import type { WorkflowIssue } from '../dataFlow';

import { toCanvasGraph } from './graph';

const block = (key: string, ports: ModuleBlock['ports']): ModuleBlock => ({
  key,
  label: key,
  executor: 'action',
  config: {},
  origin: 'web',
  reviewState: 'reviewed',
  status: 'valid',
  reason: null,
  unresolved: false,
  effect: 'read',
  description: null,
  composite: null,
  ports,
  target: {
    type: 'wrapper',
    connection: null,
    operation: 'x',
    name: 'x',
    mcpServerId: null,
    tool: null,
    toolId: 1,
    apiOperationId: null,
  },
});

const fetchBlock = block('fetch', { in: {}, out: { rows: 'list<row>' } });
const sendBlock = block('send', { in: { row: 'row', note: 'string' }, out: {} });

const withId = (step: Step, id: number, patch: Partial<Step> = {}): Step => ({ ...step, id, position: id, ...patch });
const agent = (id: number, deps: number[] = []) => withId(draftStep([], `Agent ${id}`), id, { dependsOnStepIds: deps });
const input = (steps: Step[], extra: Partial<Parameters<typeof toCanvasGraph>[0]> = {}) => ({
  steps,
  issues: [],
  blocks: [fetchBlock, sendBlock],
  selectedId: null,
  readOnly: false,
  ...extra,
});

const issue = (patch: Partial<WorkflowIssue>): WorkflowIssue => ({
  severity: 'error',
  code: 'type_mismatch',
  stepKey: '2',
  field: 'arguments.row',
  message: 'bad',
  ...patch,
});

describe('toCanvasGraph', () => {
  it('makes one node per step of every kind', () => {
    const steps = (['agent', 'approval', 'wait', 'action'] as const).map((kind, i) =>
      withId(draftStep([], `S${i}`, kind), i + 1),
    );
    const { nodes } = toCanvasGraph(input(steps));
    expect(nodes.map((n) => n.data.kindLabel)).toEqual(['Session', 'Approval', 'Wait', 'Action']);
    expect(nodes.every((n) => n.type === 'step')).toBe(true);
  });

  it('names each node for assistive tech with its dependencies and problem count', () => {
    const steps = [agent(1), agent(2, [1])];
    const { nodes } = toCanvasGraph(
      input(steps, { issues: [issue({ code: 'x', stepKey: '2', field: 'instructions' })] }),
    );
    expect(nodes[1].ariaLabel).toBe('Session Agent 2, runs after Agent 1, 1 problem');
    expect(nodes[0].ariaLabel).toBe('Session Agent 1, 0 problems');
  });

  it('draws one dependency edge per dependency and skips missing ones', () => {
    const { edges } = toCanvasGraph(input([agent(1), agent(2, [1, 99])]));
    expect(edges).toEqual([{ id: 'dep:1->2', source: '1', target: '2', sourceHandle: 'out', targetHandle: 'in' }]);
  });

  it('marks selection and locks nodes when read-only', () => {
    const { nodes } = toCanvasGraph(input([agent(1)], { selectedId: 1, readOnly: true }));
    expect(nodes[0]).toMatchObject({ selected: true, draggable: false, connectable: false, deletable: false });
  });

  describe('block ports', () => {
    const producer = withId(draftBlockStep([], fetchBlock), 1);
    const consumer = withId(draftBlockStep([], sendBlock), 2, {
      dependsOnStepIds: [1],
      kindConfig: {
        ...draftBlockStep([], sendBlock).kindConfig,
        arguments: { row: '{{output:1:rows.json}}', note: 'plain' },
      },
    });

    it('lists the ports of a loaded block and none otherwise', () => {
      const { nodes } = toCanvasGraph(input([producer, agent(3)]));
      expect(nodes[0].data.ports).toEqual({ in: [], out: [{ name: 'rows', type: 'list<row>', invalid: false }] });
      expect(nodes[1].data.ports).toBeNull();
      expect(toCanvasGraph(input([producer], { blocks: [] })).nodes[0].data.ports).toBeNull();
    });

    it('replaces the dependency edge of the same pair with a data edge', () => {
      const { edges } = toCanvasGraph(input([producer, consumer]));
      expect(edges).toEqual([
        {
          id: 'data:1.rows->2.row',
          source: '1',
          target: '2',
          sourceHandle: 'out:rows',
          targetHandle: 'in:row',
          data: { invalid: false },
        },
      ]);
    });

    it('does not treat a reference inside longer text as a binding', () => {
      const mixed = withId(consumer, 2, {
        kindConfig: { ...consumer.kindConfig, arguments: { row: 'see {{output:1:rows.json}}' } },
      });
      expect(toCanvasGraph(input([producer, mixed])).edges.map((e) => e.id)).toEqual(['dep:1->2']);
    });

    it('reports which in ports are bound and whether the step can be bound at all', () => {
      const { nodes } = toCanvasGraph(input([producer, consumer]));
      expect(nodes[1].data.binding?.bound).toEqual(['row']);
      const mcp = withId(consumer, 2, { kindConfig: { ...consumer.kindConfig, target: 'mcp_tool' } });
      expect(toCanvasGraph(input([producer, mcp])).nodes[1].data.binding?.bindable).toBe(true);
      const wrapper = withId(consumer, 2, { kindConfig: { ...consumer.kindConfig, target: 'wrapper' } });
      expect(toCanvasGraph(input([producer, wrapper])).nodes[1].data.binding?.bindable).toBe(false);
    });

    it('marks the edge and the chip of a type mismatch', () => {
      const { nodes, edges } = toCanvasGraph(input([producer, consumer], { issues: [issue({})] }));
      expect(edges[0].data).toEqual({ invalid: true });
      expect(nodes[1].data.ports?.in).toEqual([
        { name: 'row', type: 'row', invalid: true },
        { name: 'note', type: 'string', invalid: false },
      ]);
    });
  });

  it('keeps the data object of an unchanged step across calls and replaces it when its problems change', () => {
    const steps = [agent(1), agent(2)];
    const first = toCanvasGraph(input(steps)).nodes;
    const again = toCanvasGraph(input(steps, { selectedId: 2 })).nodes;
    expect(again[0].data).toBe(first[0].data);
    expect(again[1].data).toBe(first[1].data);
    const withProblem = toCanvasGraph(input(steps, { issues: [issue({ stepKey: '1', field: 'instructions' })] })).nodes;
    expect(withProblem[0].data).not.toBe(first[0].data);
    expect(withProblem[1].data).toBe(first[1].data);
  });

  it('lets a stored position win over the auto-layout', () => {
    const stored = { ...agent(1), canvasPosition: { x: 12, y: 34 } };
    const { nodes } = toCanvasGraph(input([stored, agent(2)]));
    expect(nodes[0].position).toEqual({ x: 12, y: 34 });
    expect(nodes[1].position.x).toBeGreaterThan(12);
  });
});

describe('toCanvasGraph with composite blocks', () => {
  const INSTANCE = '11111111-1111-4111-8111-111111111111';
  const member = (id: number, node: string, deps: number[] = [], patch: Partial<Step> = {}) =>
    withId(draftStep([], `Inner ${id}`), id, {
      dependsOnStepIds: deps,
      composite: { ref: 'local/invoice-flow@1', instance: INSTANCE, node },
      ...patch,
    });
  const steps = [
    agent(1),
    member(2, 'summarise', [1], { budgetCents: 40 }),
    member(3, 'send_invoice', [2]),
    agent(4, [3]),
  ];
  const composites = (extra: Partial<Parameters<typeof toCanvasGraph>[0]> = {}) =>
    toCanvasGraph(input(steps, { blocks: [buildCompositeBlock()], ...extra }));

  it('collapses an instance to one node by default and draws the edges to it', () => {
    const { nodes, groups, edges } = composites();

    expect(nodes.map((n) => n.id)).toEqual(['1', '4']);
    expect(groups.map((n) => [n.id, n.data.expanded])).toEqual([[`group:${INSTANCE}`, false]]);
    expect(edges.map((e) => [e.source, e.target])).toEqual([
      ['1', `group:${INSTANCE}`],
      [`group:${INSTANCE}`, '4'],
    ]);
  });

  it('puts the node at the top-left of its steps', () => {
    const placed = steps.map((s) =>
      s.id === 2
        ? { ...s, canvasPosition: { x: 300, y: 40 } }
        : s.id === 3
          ? { ...s, canvasPosition: { x: 620, y: 10 } }
          : s,
    );

    const { groups } = toCanvasGraph(input(placed, { blocks: [buildCompositeBlock()] }));

    expect(groups[0].position).toEqual({ x: 300, y: 10 });
  });

  it('shows the steps and a frame behind them when the instance is expanded, and leaves the edges alone', () => {
    const { nodes, groups, edges } = composites({ expanded: new Set([INSTANCE]) });

    expect(nodes.map((n) => n.id)).toEqual(['1', '2', '3', '4']);
    expect(groups.map((n) => [n.id, n.data.expanded, n.zIndex])).toEqual([[`frame:${INSTANCE}`, true, -1]]);
    expect(edges.map((e) => e.id)).toEqual(['dep:1->2', 'dep:2->3', 'dep:3->4']);
  });

  it('gathers the problems of the inner steps on the node, each with its step', () => {
    const { groups } = composites({
      issues: [
        issue({ stepKey: '2', field: 'instructions' }),
        issue({ stepKey: '3', field: 'instructions' }),
        issue({ stepKey: '1' }),
      ],
    });

    expect(groups[0].data.problems.map((p) => [p.step.id, p.issues.length])).toEqual([
      [2, 1],
      [3, 1],
    ]);
    expect(groups[0].ariaLabel).toBe('Group Invoice flow, 2 steps, 2 problems, collapsed');
  });

  it('summarises the block: ports, the sum of the caps and a newer version', () => {
    const { groups } = composites({
      blocks: [buildCompositeBlock(), buildCompositeBlock({ key: 'local/invoice-flow@2' })],
    });

    expect(groups[0].data.summary).toMatchObject({ label: 'Invoice flow', capCents: 40, newerVersion: 2 });
  });

  it('makes a group draggable only when the canvas is editable', () => {
    expect(composites().groups[0].draggable).toBe(true);
    expect(composites({ readOnly: true }).groups[0].draggable).toBe(false);
  });
});
