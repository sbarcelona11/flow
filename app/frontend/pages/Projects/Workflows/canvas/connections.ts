import type { Step } from '@/types/generated';

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
