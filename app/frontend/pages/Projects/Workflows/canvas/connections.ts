import type { ModuleBlock, Step } from '@/types/generated';

import { MAX_OUTPUT_TOKENS, type PortBinding } from '../actionArguments';
import { withDependency } from '../builderDraft';

export type Refusal = 'self' | 'exists' | 'cycle';

/** Why `stepId` cannot run after `dependencyId`: the structural rules only, never type or governance rules. */
export function dependencyRefusal(steps: Step[], stepId: number, dependencyId: number): Refusal | null {
  if (stepId === dependencyId) return 'self';
  if (steps.find((s) => s.id === stepId)?.dependsOnStepIds.includes(dependencyId)) return 'exists';
  return withDependency(steps, stepId, dependencyId) ? null : 'cycle';
}

/** The steps `stepId` could be made to run after. */
export function eligibleDependencies(steps: Step[], stepId: number): Step[] {
  return steps.filter((s) => dependencyRefusal(steps, stepId, s.id) === null);
}

export function refusalMessage(refusal: Refusal, stepName: string, dependencyName: string): string {
  if (refusal === 'self') return `${stepName} cannot run after itself`;
  if (refusal === 'exists') return `${stepName} already runs after ${dependencyName}`;
  return `${stepName} cannot run after ${dependencyName}: that would make the workflow loop back on itself`;
}

export type HandleType = 'source' | 'target';

export interface Drop {
  /** The handle the drag started on: `source` is an out handle, `target` an in handle. */
  fromType: HandleType;
  toType: HandleType;
  fromId: number;
  toId: number;
}

/** Who runs after whom in a drop; none when both ends are the same kind of handle. */
export function orientDrop({ fromType, toType, fromId, toId }: Drop): { stepId: number; dependencyId: number } | null {
  if (fromType === toType) return null;
  return fromType === 'source' ? { stepId: toId, dependencyId: fromId } : { stepId: fromId, dependencyId: toId };
}

/** Why a drop React Flow refused did nothing; null when the drop is acceptable. */
export function dropMessage(steps: Step[], drop: Drop): string | null {
  const oriented = orientDrop(drop);
  if (!oriented) return 'Connect a step’s out handle to another step’s in handle';
  const refusal = dependencyRefusal(steps, oriented.stepId, oriented.dependencyId);
  if (!refusal) return null;
  const name = (id: number) => steps.find((s) => s.id === id)?.name ?? 'A step';
  return refusalMessage(refusal, name(oriented.stepId), name(oriented.dependencyId));
}

export interface BindingOption {
  stepId: number;
  stepName: string;
  port: string;
  /** The declared port type, shown as text; never compared with the argument's. */
  type: string | null;
}

/** Every out port of an action step `targetId` could run after, for a "Bind to…" menu. */
export function bindingOptions(steps: Step[], blocks: ModuleBlock[], targetId: number): BindingOption[] {
  const byKey = new Map(blocks.map((b) => [b.key, b]));
  return steps.flatMap((source) => {
    const refusal = dependencyRefusal(steps, targetId, source.id);
    const key = source.kind === 'action' ? source.kindConfig.block : undefined;
    const block = key ? byKey.get(key) : undefined;
    if (!block || (refusal !== null && refusal !== 'exists')) return [];
    return Object.entries(block.ports.out ?? {}).map(([port, type]) => ({
      stepId: source.id,
      stepName: source.name,
      port,
      type: type ?? null,
    }));
  });
}

/** Why a binding `withPortBinding` refused did nothing. */
export function bindingRefusalMessage(steps: Step[], { from, to }: PortBinding): string {
  const name = (id: number) => steps.find((s) => s.id === id)?.name ?? 'A step';
  const target = steps.find((s) => s.id === to);
  if (target?.kindConfig.target === 'wrapper') return `${name(to)} is a Wrapper action and cannot read step outputs`;
  const refusal = dependencyRefusal(steps, to, from);
  if (refusal && refusal !== 'exists') return refusalMessage(refusal, name(to), name(from));
  return `${name(to)} already reads ${MAX_OUTPUT_TOKENS} step outputs, the most one action can`;
}
