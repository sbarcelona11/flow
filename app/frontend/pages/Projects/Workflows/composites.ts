import type { Edge } from '@xyflow/react';

import type { ModuleBlock, Step } from '@/types/generated';

import { plainLine } from 'shared/resources/connectors/reviewText';

/** A step as `POST blocks/expand` returns it: the aggregate's snake_case shape, keyed `new-<n>`. */
export interface ExpandedStep {
  key: string;
  name: string;
  kind: Step['kind'];
  instructions?: string | null;
  kind_config?: Record<string, unknown>;
  depends_on_step_ids?: (number | string)[];
  sub_steps?: { name: string; instructions?: string | null; required?: boolean }[];
  canvas_position?: { x: number; y: number } | null;
  composite?: Step['composite'];
  budget_cents?: number | null;
  input_asset_specs?: { name: string; asset_type: string; required?: boolean }[];
  output_asset_specs?: { name: string; asset_type: string; required?: boolean; name_pattern?: string | null }[];
  agent_id?: number | null;
  [field: string]: unknown;
}

export interface Expansion {
  steps: ExpandedStep[];
  warnings: string[];
  instance: string;
  /** In ports the caller left unbound. */
  unbound: string[];
}

const GROUP_PREFIX = 'group:';
const FRAME_PREFIX = 'frame:';

/** The id of the one node that stands for a collapsed instance. */
export const groupNodeId = (instance: string) => `${GROUP_PREFIX}${instance}`;
/** The id of the frame drawn behind an expanded instance's steps. */
export const frameNodeId = (instance: string) => `${FRAME_PREFIX}${instance}`;

/** The instance a group or frame node stands for; null for a step node. */
export function instanceOfNode(nodeId: string): string | null {
  if (nodeId.startsWith(GROUP_PREFIX)) return nodeId.slice(GROUP_PREFIX.length);
  if (nodeId.startsWith(FRAME_PREFIX)) return nodeId.slice(FRAME_PREFIX.length);
  return null;
}

/** Every instance in the draft with its steps, in step order. */
export function instancesOf(steps: Step[]): Map<string, Step[]> {
  const found = new Map<string, Step[]>();
  for (const step of steps) {
    const instance = step.composite?.instance;
    if (instance) found.set(instance, [...(found.get(instance) ?? []), step]);
  }
  return found;
}

export const membersOf = (steps: Step[], instance: string): Step[] =>
  steps.filter((s) => s.composite?.instance === instance);

/** The id of the node that draws `step`: its group while the instance is collapsed, itself otherwise. */
export function nodeIdOf(step: Step, expanded: ReadonlySet<string>): string {
  const instance = step.composite?.instance;
  return instance && !expanded.has(instance) ? groupNodeId(instance) : String(step.id);
}

/**
 * The edges with each end that belongs to a collapsed instance moved to its group node. An edge inside one group
 * disappears, and edges that end up between the same two nodes become one. Such an edge is not a dependency a person
 * can remove: it stands for several.
 */
export function rerouteEdges(edges: Edge[], steps: Step[], expanded: ReadonlySet<string>): Edge[] {
  const nodeOf = new Map(steps.map((s) => [String(s.id), nodeIdOf(s, expanded)]));
  const rerouted = new Map<string, Edge>();
  const result: Edge[] = [];
  for (const edge of edges) {
    const source = nodeOf.get(edge.source) ?? edge.source;
    const target = nodeOf.get(edge.target) ?? edge.target;
    if (source === edge.source && target === edge.target) {
      result.push(edge);
      continue;
    }
    if (source === target) continue;
    const key = `${source}->${target}`;
    const invalid = (edge.data as { invalid?: boolean } | undefined)?.invalid === true;
    const known = rerouted.get(key);
    if (known) {
      if (invalid) known.data = { invalid: true };
      continue;
    }
    const grouped: Edge = { id: `grp:${key}`, source, target, sourceHandle: 'out', targetHandle: 'in' };
    if (invalid) grouped.data = { invalid: true };
    rerouted.set(key, grouped);
    result.push(grouped);
  }
  return result;
}

/** Every `{{output:<key>:…}}` and `{{step:<key>}}` token in the strings of `value`, with `key` replaced through `keys`. */
export function rewriteKeys<T>(value: T, keys: ReadonlyMap<string, string>): T {
  const rewrite = (text: string) =>
    text
      .replace(/\{\{output:([^:{}\n]+):([^{}\n]+)\}\}/g, (token, key: string, file: string) =>
        keys.has(key) ? `{{output:${keys.get(key)}:${file}}}` : token,
      )
      .replace(/\{\{step:([^{}\n]+)\}\}/g, (token, key: string) =>
        keys.has(key) ? `{{step:${keys.get(key)}}}` : token,
      );
  const walk = (node: unknown): unknown => {
    if (typeof node === 'string') return rewrite(node);
    if (Array.isArray(node)) return node.map(walk);
    if (typeof node === 'object' && node !== null)
      return Object.fromEntries(Object.entries(node).map(([k, v]) => [k, walk(v)]));
    return node;
  };
  return walk(value) as T;
}

const camel = (name: string) => name.replace(/_([a-z])/g, (_, letter: string) => letter.toUpperCase());

/** The keys of an object camelised one level deep; the values are left alone. */
const camelKeys = <T extends object>(object: T): Record<string, unknown> =>
  Object.fromEntries(Object.entries(object).map(([key, value]) => [camel(key), value]));

/** `kind_config` with camelCase keys; `arguments` names an operation's own arguments and stays as it is. */
export const kindConfigFrom = (config: Record<string, unknown> | undefined): Step['kindConfig'] =>
  (config ? camelKeys(config) : {}) as Step['kindConfig'];

export const assetSpecsFrom = <T extends object>(specs: T[] | undefined) => (specs ?? []).map(camelKeys);

/** A block as shown to a person: its label from the module, or its slug when the module is no longer listed. */
export function blockLabel(ref: string, blocks: ModuleBlock[]): string {
  const known = blocks.find((b) => b.key === ref)?.label;
  return plainLine(known ?? /\/([^/@]+)@/.exec(ref)?.[1] ?? ref, 80);
}

const REF = /^([^/]+)\/([^@]+)@(\d+)$/;

/** The highest enabled, valid version of the same block above the one the instance was made from, or null. */
export function newerVersion(ref: string, blocks: ModuleBlock[]): number | null {
  const parsed = REF.exec(ref);
  if (!parsed) return null;
  const [, namespace, slug, version] = parsed;
  const higher = blocks
    .filter((b) => b.executor === 'composite' && b.status === 'valid')
    .map((b) => REF.exec(b.key))
    .filter((m): m is RegExpExecArray => m !== null && m[1] === namespace && m[2] === slug)
    .map((m) => Number(m[3]))
    .filter((v) => v > Number(version));
  return higher.length > 0 ? Math.max(...higher) : null;
}

export interface GroupPort {
  name: string;
  type: string | null;
  /** Null when binding the port later is not possible, or it is not known whether it is connected. */
  connected: boolean | null;
}

export interface GroupSummary {
  ref: string;
  label: string;
  /** False when the module is no longer listed (disabled, archived), so nothing is known of its ports. */
  known: boolean;
  steps: Step[];
  ports: { in: GroupPort[]; out: GroupPort[] };
  /** The sum of the inner steps' caps, for display only; null when none has one. */
  capCents: number | null;
  newerVersion: number | null;
}

const hasValue = (value: unknown) => (typeof value === 'string' ? value.trim() !== '' : value != null);

/** What a collapsed node shows about an instance, from its steps and the block it came from. */
export function summarizeGroup(members: Step[], blocks: ModuleBlock[]): GroupSummary {
  const ref = members[0]?.composite?.ref ?? '';
  const block = blocks.find((b) => b.key === ref);
  const composite = block?.composite ?? null;
  const connected = (targets: { node: string; argument: string }[]) =>
    targets.length === 0
      ? null
      : targets.every(({ node, argument }) =>
          members.some((s) => s.composite?.node === node && hasValue(s.kindConfig.arguments?.[argument])),
        );
  const capped = members.filter((s) => (s.kind === 'agent' || s.kind === 'action') && s.budgetCents != null);
  return {
    ref,
    label: blockLabel(ref, blocks),
    known: composite !== null,
    steps: members,
    ports: {
      in: Object.entries(composite?.ports.in ?? {}).map(([name, port]) => ({
        name,
        type: port.type,
        connected: connected(port.targets),
      })),
      out: Object.entries(composite?.ports.out ?? {}).map(([name, port]) => ({
        name,
        type: port.type,
        connected: null,
      })),
    },
    capCents: capped.length > 0 ? capped.reduce((sum, s) => sum + (s.budgetCents ?? 0), 0) : null,
    newerVersion: newerVersion(ref, blocks),
  };
}
