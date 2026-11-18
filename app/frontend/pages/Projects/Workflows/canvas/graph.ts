import type { Edge, Node } from '@xyflow/react';

import type { ModuleBlock, Step } from '@/types/generated';

import { scanReferences } from 'shared/lib/references';

import { KIND_LABELS, stepKey } from '../builderDraft';
import type { WorkflowIssue } from '../dataFlow';

import { NODE_HEIGHT, NODE_WIDTH, resolvePositions, type LayoutStep } from './layout';

export interface PortChip {
  name: string;
  type: string | null;
  invalid: boolean;
}

export interface StepNodeData extends Record<string, unknown> {
  step: Step;
  kindLabel: string;
  problems: WorkflowIssue[];
  ports: { in: PortChip[]; out: PortChip[] } | null;
  /** Null unless the step is a block. `bound`: in ports fed by another step's output. `bindable`: false for a Wrapper target, which cannot read step outputs. */
  binding: { bound: string[]; bindable: boolean } | null;
  blockLabel: string | null;
}

export type StepNode = Node<StepNodeData, 'step'>;

export interface CanvasGraphInput {
  steps: (Step & Pick<LayoutStep, 'canvasPosition'>)[];
  issues: WorkflowIssue[];
  blocks: ModuleBlock[];
  selectedId: number | null;
  readOnly: boolean;
  /** Precomputed `resolvePositions(steps)`, so a caller can memoise the layout on `layoutKey`. */
  positions?: Map<number, { x: number; y: number }>;
}

const MISMATCH_FIELD = /^arguments\.(.+)$/;

const chipsEqual = (a: PortChip[], b: PortChip[]) =>
  a.length === b.length &&
  a.every((c, i) => c.name === b[i].name && c.type === b[i].type && c.invalid === b[i].invalid);

const sameData = (a: StepNodeData, b: StepNodeData) =>
  (a.binding === null
    ? b.binding === null
    : b.binding !== null &&
      a.binding.bindable === b.binding.bindable &&
      a.binding.bound.join() === b.binding.bound.join()) &&
  a.kindLabel === b.kindLabel &&
  a.blockLabel === b.blockLabel &&
  a.problems.length === b.problems.length &&
  a.problems.every((p, i) => p === b.problems[i]) &&
  (a.ports === null
    ? b.ports === null
    : b.ports !== null && chipsEqual(a.ports.in, b.ports.in) && chipsEqual(a.ports.out, b.ports.out));

// A step that has not changed keeps its `data` object, so a memoised node does not re-render.
const dataCache = new WeakMap<Step, StepNodeData>();

function stableData(step: Step, next: StepNodeData): StepNodeData {
  const cached = dataCache.get(step);
  if (cached && sameData(cached, next)) return cached;
  dataCache.set(step, next);
  return next;
}

function portChips(ports: Record<string, string> | undefined, invalid: Set<string>): PortChip[] {
  return Object.entries(ports ?? {}).map(([name, type]) => ({ name, type: type ?? null, invalid: invalid.has(name) }));
}

function ariaLabel(step: Step, kindLabel: string, steps: Step[], problems: number): string {
  const after = step.dependsOnStepIds
    .map((id) => steps.find((s) => s.id === id)?.name)
    .filter((name): name is string => Boolean(name));
  const runs = after.length > 0 ? `, runs after ${after.join(', ')}` : '';
  return `${kindLabel} ${step.name}${runs}, ${problems} ${problems === 1 ? 'problem' : 'problems'}`;
}

/** The workflow draft as React Flow nodes and edges: nodes are steps, edges are dependencies and bound block ports. */
export function toCanvasGraph({ steps, issues, blocks, selectedId, readOnly, positions: given }: CanvasGraphInput): {
  nodes: StepNode[];
  edges: Edge[];
} {
  const blockByKey = new Map(blocks.map((b) => [b.key, b]));
  const blockOf = (step: Step) =>
    step.kind === 'action' && step.kindConfig.block ? blockByKey.get(step.kindConfig.block) : undefined;
  const stepByKey = new Map(steps.map((s) => [stepKey(s.id), s]));

  const problemsByKey = new Map<string, WorkflowIssue[]>();
  const invalidArgs = new Map<string, Set<string>>();
  for (const issue of issues) {
    problemsByKey.set(issue.stepKey, [...(problemsByKey.get(issue.stepKey) ?? []), issue]);
    const arg = issue.code === 'type_mismatch' ? MISMATCH_FIELD.exec(issue.field)?.[1] : undefined;
    if (arg) invalidArgs.set(issue.stepKey, (invalidArgs.get(issue.stepKey) ?? new Set()).add(arg));
  }

  const dataEdges: Edge[] = [];
  const joined = new Set<string>();
  const bound = new Map<string, Set<string>>();
  for (const target of steps) {
    const targetBlock = blockOf(target);
    const args = target.kindConfig.arguments;
    if (!targetBlock || !args) continue;
    for (const [arg, value] of Object.entries(args)) {
      if (typeof value !== 'string' || !(arg in (targetBlock.ports.in ?? {}))) continue;
      const refs = scanReferences(value);
      const ref =
        refs.length === 1 && refs[0].token === value && refs[0].kind === 'output' && refs[0].valid ? refs[0] : null;
      const source = ref?.stepRef ? stepByKey.get(ref.stepRef) : undefined;
      const port = ref?.name?.replace(/\.json$/, '');
      const sourceBlock = source && blockOf(source);
      if (!source || !port || !sourceBlock || !(port in (sourceBlock.ports.out ?? {}))) continue;
      joined.add(`${source.id}->${target.id}`);
      const key = stepKey(target.id);
      bound.set(key, (bound.get(key) ?? new Set()).add(arg));
      dataEdges.push({
        id: `data:${source.id}.${port}->${target.id}.${arg}`,
        source: String(source.id),
        target: String(target.id),
        sourceHandle: `out:${port}`,
        targetHandle: `in:${arg}`,
        data: { invalid: invalidArgs.get(stepKey(target.id))?.has(arg) ?? false },
      });
    }
  }

  const positions = given ?? resolvePositions(steps);
  const nodes: StepNode[] = steps.map((step) => {
    const key = stepKey(step.id);
    const block = blockOf(step);
    const problems = problemsByKey.get(key) ?? [];
    const kindLabel = KIND_LABELS[step.kind];
    const data = stableData(step, {
      step,
      kindLabel,
      problems,
      blockLabel: block?.label ?? null,
      ports: block
        ? {
            in: portChips(block.ports.in, invalidArgs.get(key) ?? new Set()),
            out: portChips(block.ports.out, new Set()),
          }
        : null,
      binding: block ? { bound: [...(bound.get(key) ?? [])], bindable: step.kindConfig.target !== 'wrapper' } : null,
    });
    return {
      id: String(step.id),
      type: 'step',
      position: positions.get(step.id) as { x: number; y: number },
      // Until React Flow has measured the node (it grows with its content), these keep it in view.
      initialWidth: NODE_WIDTH,
      initialHeight: NODE_HEIGHT,
      data,
      selected: step.id === selectedId,
      draggable: !readOnly,
      connectable: !readOnly,
      deletable: !readOnly,
      ariaLabel: ariaLabel(step, kindLabel, steps, problems.length),
    };
  });

  const ids = new Set(steps.map((s) => s.id));
  const dependencyEdges: Edge[] = steps.flatMap((to) =>
    to.dependsOnStepIds
      .filter((from) => ids.has(from) && !joined.has(`${from}->${to.id}`))
      .map((from) => ({
        id: `dep:${from}->${to.id}`,
        source: String(from),
        target: String(to.id),
        sourceHandle: 'out',
        targetHandle: 'in',
      })),
  );

  return { nodes, edges: [...dependencyEdges, ...dataEdges] };
}
