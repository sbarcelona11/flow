import type { ModuleBlock, Step } from '@/types/generated';

import { MAX_OUTPUT_TOKENS, type PortBinding, withoutPortBinding, withPortBinding } from '../actionArguments';
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
  /** The output file, for a composite block's out port; otherwise it is `<port>.json`. */
  file?: string;
}

/** Every out port, that the step declares as an output file (`<port>.json`), of a step `targetId` could run after. */
export function bindingOptions(steps: Step[], blocks: ModuleBlock[], targetId: number | null): BindingOption[] {
  const byKey = new Map(blocks.map((b) => [b.key, b]));
  return steps.flatMap((source) => {
    const refusal = targetId === null ? null : dependencyRefusal(steps, targetId, source.id);
    if (refusal !== null && refusal !== 'exists') return [];
    const declared = new Set(source.outputAssetSpecs.map((spec) => spec.name));
    const key = source.kind === 'action' ? source.kindConfig.block : undefined;
    const block = key ? byKey.get(key) : undefined;
    const own: BindingOption[] = Object.entries(block?.ports.out ?? {})
      .filter(([port]) => declared.has(`${port}.json`))
      .map(([port, type]) => ({ stepId: source.id, stepName: source.name, port, type: type ?? null }));
    // A step that came from a composite block is also offered under the block's own out port for it.
    const group = source.composite ? byKey.get(source.composite.ref)?.composite : null;
    const exposed: BindingOption[] = Object.entries(group?.ports.out ?? {})
      .filter(([, port]) => port.step === source.composite?.node && declared.has(port.output))
      .filter(([, port]) => !own.some((o) => `${o.port}.json` === port.output))
      .map(([port, { type, output }]) => ({
        stepId: source.id,
        stepName: source.name,
        port,
        type,
        file: output,
      }));
    return [...own, ...exposed];
  });
}

/** The steps of `instance` that take `port` as an argument's whole value, as the block's manifest names them. */
function portTargets(steps: Step[], blocks: ModuleBlock[], instance: string, port: string) {
  const members = steps.filter((s) => s.composite?.instance === instance);
  const targets = blocks.find((b) => b.key === members[0]?.composite?.ref)?.composite?.ports.in[port]?.targets ?? [];
  return targets.flatMap(({ node, argument }) => {
    const step = members.find((s) => s.composite?.node === node);
    return step ? [{ stepId: step.id, argument }] : [];
  });
}

/** The step that takes the group's in port, whose "Bind to…" options apply to it; null when the port cannot be bound. */
export const groupPortTargetStepId = (steps: Step[], blocks: ModuleBlock[], instance: string, port: string) =>
  portTargets(steps, blocks, instance, port)[0]?.stepId ?? null;

/** Whether an in port of a group can be bound after insertion: its manifest names an argument to write to. */
export const groupPortBindable = (steps: Step[], blocks: ModuleBlock[], instance: string, port: string) =>
  portTargets(steps, blocks, instance, port).length > 0;

/**
 * The steps with the argument(s) the block names for `port` fed by `option`'s output, and each of those steps running
 * after its producer. All or nothing: `null` when there is nothing to write to or any one binding is refused.
 */
export function withGroupPortBinding(
  steps: Step[],
  blocks: ModuleBlock[],
  instance: string,
  port: string,
  option: BindingOption,
): Step[] | null {
  const targets = portTargets(steps, blocks, instance, port);
  if (targets.length === 0) return null;
  let result: Step[] | null = steps;
  for (const { stepId, argument } of targets) {
    result =
      result &&
      withPortBinding(result, { from: option.stepId, port: option.port, file: option.file, to: stepId, argument });
  }
  return result;
}

/** The steps with the arguments of `port` cleared; the dependencies stay. */
export function withoutGroupPortBinding(steps: Step[], blocks: ModuleBlock[], instance: string, port: string): Step[] {
  return portTargets(steps, blocks, instance, port).reduce(
    (acc, { stepId, argument }) => withoutPortBinding(acc, stepId, argument),
    steps,
  );
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
