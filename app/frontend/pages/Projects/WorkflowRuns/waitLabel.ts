import type StepRun from 'types/generated/StepRun';

export function formatWaitUntil(iso: string, locale?: string, timeZone?: string): string {
  return new Date(iso).toLocaleString(locale, { dateStyle: 'medium', timeStyle: 'short', timeZone });
}

export function waitLabel(step: StepRun): string | null {
  return step.waitUntil ? `Waiting until ${formatWaitUntil(step.waitUntil)}` : null;
}
