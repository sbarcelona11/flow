import type StepRun from 'types/generated/StepRun';

export function waitLabel(step: StepRun): string | null {
  const { delaySeconds, untilContextKey } = step.stepKindConfig;
  if (untilContextKey) return `Waiting for the time in ${untilContextKey}`;
  if (delaySeconds === undefined || !step.startedAt) return null;
  return `Waiting until ${new Date(new Date(step.startedAt).getTime() + delaySeconds * 1000).toLocaleString()}`;
}
