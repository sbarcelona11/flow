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
