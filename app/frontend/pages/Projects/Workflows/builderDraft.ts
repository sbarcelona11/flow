import type { ModuleBlock, Step, SubStep, Workflow } from '@/types/generated';

import { sanitizeCapCents } from 'shared/lib/budgetCap';
import { scanReferences } from 'shared/lib/references';

import { assetSpecsFrom, type Expansion, kindConfigFrom, rewriteKeys } from './composites';
import { downstreamIds } from './dataFlow';
import type { Selection } from './SessionTreeNav';

// The builder edits a local draft of the whole workflow and saves it in one
// request (PUT …/workflows/:id/aggregate). Steps and sub-steps created since the
// last save carry negative ids until the server hands back real ones.

const now = () => new Date().toISOString();

function nextDraftId(steps: Step[]): number {
  const ids = steps.flatMap((s) => [s.id, ...s.subSteps.map((ss) => ss.id)]);
  return Math.min(0, ...ids) - 1;
}

export const isDraftId = (id: number) => id < 0;

export type StepKind = Step['kind'];

export const isControlKind = (kind: StepKind) => kind === 'approval' || kind === 'wait';
export const runsSession = (kind: StepKind) => !isControlKind(kind) && kind !== 'action';

export const ACTION_OUTPUT_DEFAULT = 'result.json';

export const CONTROL_STEP_MAX_SECONDS = 518_400;
export const APPROVAL_DEFAULT_SECONDS = 86_400;
export const WAIT_DEFAULT_SECONDS = 3_600;

export const KIND_LABELS: Record<StepKind, string> = {
  agent: 'Session',
  approval: 'Approval',
  wait: 'Wait',
  action: 'Action',
};

export function defaultKindConfig(kind: StepKind): Step['kindConfig'] {
  if (kind === 'approval') return { timeoutSeconds: APPROVAL_DEFAULT_SECONDS, onTimeout: 'fail' };
  if (kind === 'wait') return { delaySeconds: WAIT_DEFAULT_SECONDS };
  if (kind === 'action') return { arguments: {}, effect: 'write', outputName: ACTION_OUTPUT_DEFAULT };
  return {};
}

/** An action step for a block: the block's operation as the target, the block as provenance, its first out port as the file. */
export function draftBlockStep(steps: Step[], block: ModuleBlock, canvasPosition: Point | null = null): Step {
  const { target } = block;
  const outPort = Object.keys(block.ports.out ?? {})[0];
  const outputName = outPort ? `${outPort}.json` : ACTION_OUTPUT_DEFAULT;
  const step = draftStep(steps, block.label, 'action', canvasPosition);
  return {
    ...step,
    kindConfig: {
      target: target?.type,
      ...(target?.type === 'wrapper'
        ? { toolId: target.toolId ?? undefined }
        : target?.type === 'rest_operation'
          ? { apiOperationId: target.apiOperationId ?? undefined }
          : { mcpServerId: target?.mcpServerId ?? undefined, tool: target?.tool ?? undefined }),
      arguments: {},
      effect: block.effect ?? 'write',
      outputName,
      block: block.key,
    },
    outputAssetSpecs: actionOutputSpecs(outputName),
  };
}

export const actionOutputSpecs = (name: string): Step['outputAssetSpecs'] => [
  { name, assetType: 'file', required: true, namePattern: null },
];

function defaultOutputSpecs(kind: StepKind): Step['outputAssetSpecs'] {
  return kind === 'action' ? actionOutputSpecs(ACTION_OUTPUT_DEFAULT) : [];
}

/** The step as another kind: kinds that run no session take no agent, resources, inputs, retry or skip policy, and an action's only output is its file. */
export function withKind(step: Step, kind: StepKind): Step {
  if (kind === step.kind) return step;
  const cleared = !runsSession(kind)
    ? {
        agentId: null,
        requiredAgentRuntime: null,
        preferredModel: null,
        reasoningEffort: null,
        allowNonInteractive: true,
        bmadEnabled: false,
        inputAssetSpecs: [],
        outputAssetSpecs: defaultOutputSpecs(kind),
        toolIds: [],
        skillIds: [],
        mcpServerIds: [],
        assetIds: [],
        repositoryIds: [],
        configItemIds: [],
        onFailure: 'fail' as const,
        maxRetries: 0,
        skipPolicy: 'never' as const,
      }
    : step.kind === 'action'
      ? { outputAssetSpecs: [] }
      : {};
  return { ...step, ...cleared, kind, kindConfig: defaultKindConfig(kind) };
}

export function draftStep(
  steps: Step[],
  name: string,
  kind: StepKind = 'agent',
  canvasPosition: Point | null = null,
): Step {
  const position = steps.length > 0 ? Math.max(...steps.map((s) => s.position)) + 1 : 1;
  return {
    id: nextDraftId(steps),
    name: name || `${KIND_LABELS[kind]} ${position}`,
    instructions: null,
    position,
    allowNonInteractive: !runsSession(kind),
    kind,
    kindConfig: defaultKindConfig(kind),
    skipPolicy: 'never',
    onFailure: 'fail',
    maxRetries: 0,
    bmadEnabled: false,
    preferredModel: null,
    reasoningEffort: null,
    createdAt: now(),
    updatedAt: now(),
    repositoryIds: [],
    dependsOnStepIds: [],
    inputAssetSpecs: [],
    outputAssetSpecs: defaultOutputSpecs(kind),
    agentId: null,
    requiredAgentRuntime: null,
    toolIds: [],
    mcpServerIds: [],
    skillIds: [],
    configItemIds: [],
    assetIds: [],
    subSteps: [],
    budgetCents: null,
    canvasPosition: canvasPosition && clamped({ x: Math.round(canvasPosition.x), y: Math.round(canvasPosition.y) }),
    composite: null,
  };
}

const DRAFT_KEY = /^new-([1-9]\d*)$/;

/**
 * The draft steps an expanded composite block makes, ready to append to `steps`. Each gets the next free draft id; the
 * `new-<n>` keys of the expansion become those ids' keys in `depends_on_step_ids` and in every `{{output:…}}` and
 * `{{step:…}}` token, so bindings the person chose carry over, and a binding naming a step already in the draft stays.
 * With `origin` the steps keep the layout the server gave them, moved so its top-left corner is there; without it they
 * have no stored position.
 */
export function draftCompositeSteps(steps: Step[], expansion: Expansion, origin: Point | null = null): Step[] {
  let next = nextDraftId(steps);
  const ids = new Map(expansion.steps.map((s) => [s.key, next--]));
  const keys = new Map([...ids].map(([key, id]) => [key, stepKey(id)]));
  const first = steps.length > 0 ? Math.max(...steps.map((s) => s.position)) + 1 : 1;
  const given = expansion.steps.flatMap((s) => (s.canvas_position ? [s.canvas_position] : []));
  const left = Math.min(0, ...given.map((p) => p.x));
  const top = Math.min(0, ...given.map((p) => p.y));
  const dependency = (dep: number | string): number | null => {
    if (typeof dep === 'number') return dep;
    const known = ids.get(dep);
    if (known !== undefined) return known;
    const draft = DRAFT_KEY.exec(dep);
    if (draft) return -Number(draft[1]);
    return /^[1-9]\d*$/.test(dep) ? Number(dep) : null;
  };

  return expansion.steps.map((e, index) => {
    const id = ids.get(e.key) as number;
    const placed = e.canvas_position;
    const base = draftStep([], e.name, e.kind);
    const config = kindConfigFrom(rewriteKeys(e.kind_config, keys));
    return {
      ...base,
      id,
      position: first + index,
      instructions: e.instructions == null ? null : rewriteKeys(e.instructions, keys),
      kindConfig: Object.keys(config).length > 0 ? config : base.kindConfig,
      budgetCents: e.budget_cents ?? null,
      allowNonInteractive: (e.allow_non_interactive as boolean | undefined) ?? base.allowNonInteractive,
      skipPolicy: (e.skip_policy as Step['skipPolicy'] | undefined) ?? base.skipPolicy,
      onFailure: (e.on_failure as Step['onFailure'] | undefined) ?? base.onFailure,
      maxRetries: (e.max_retries as number | undefined) ?? base.maxRetries,
      preferredModel: (e.preferred_model as string | null | undefined) ?? null,
      requiredAgentRuntime: (e.required_agent_runtime as string | null | undefined) ?? null,
      agentId: e.agent_id ?? null,
      toolIds: (e.tool_ids as number[] | undefined) ?? [],
      skillIds: (e.skill_ids as number[] | undefined) ?? [],
      mcpServerIds: (e.mcp_server_ids as number[] | undefined) ?? [],
      repositoryIds: (e.repository_ids as number[] | undefined) ?? [],
      assetIds: (e.asset_ids as number[] | undefined) ?? [],
      configItemIds: (e.config_item_ids as number[] | undefined) ?? [],
      inputAssetSpecs: assetSpecsFrom(e.input_asset_specs) as Step['inputAssetSpecs'],
      outputAssetSpecs: assetSpecsFrom(e.output_asset_specs) as Step['outputAssetSpecs'],
      dependsOnStepIds: (e.depends_on_step_ids ?? []).flatMap((dep) => dependency(dep) ?? []),
      subSteps: (e.sub_steps ?? []).map((sub, i) => ({
        id: next--,
        stepId: id,
        name: sub.name,
        instructions: sub.instructions == null ? null : rewriteKeys(sub.instructions, keys),
        position: i + 1,
        required: sub.required ?? true,
        createdAt: now(),
        updatedAt: now(),
      })),
      composite: e.composite ?? null,
      canvasPosition:
        origin && placed
          ? clamped({ x: Math.round(origin.x + placed.x - left), y: Math.round(origin.y + placed.y - top) })
          : null,
    };
  });
}

/** The steps of the instance without their provenance: they stay as ordinary steps, nothing else changes. */
export function ungroup(steps: Step[], instance: string): Step[] {
  return steps.map((s) => (s.composite?.instance === instance ? { ...s, composite: null } : s));
}

/** The steps with `nodes` (step id to graph key) marked as one instance of `ref`; nothing is created or changed but the mark. */
export function withProvenance(
  steps: Step[],
  ref: string,
  instance: string,
  nodes: ReadonlyMap<number, string>,
): Step[] {
  return steps.map((s) =>
    nodes.has(s.id) ? { ...s, composite: { ref, instance, node: nodes.get(s.id) as string } } : s,
  );
}

/**
 * The steps with a new approval placed just before the action and made one of its dependencies.
 * The approval waits for what the action waited for, so it asks only once that is done.
 */
export function withApprovalBefore(steps: Step[], actionId: number): { steps: Step[]; approval: Step } | null {
  const action = steps.find((s) => s.id === actionId);
  if (!action) return null;
  const approval: Step = {
    ...draftStep(steps, `Approve ${action.name}`, 'approval'),
    position: action.position,
    dependsOnStepIds: action.dependsOnStepIds,
  };
  const shifted = steps.map((s) => {
    const moved = s.position >= action.position ? { ...s, position: s.position + 1 } : s;
    return s.id === actionId ? { ...moved, dependsOnStepIds: [...s.dependsOnStepIds, approval.id] } : moved;
  });
  return { steps: [...shifted, approval], approval };
}

export function draftSubStep(steps: Step[], step: Step, name?: string): SubStep {
  const position = step.subSteps.length + 1;
  return {
    id: nextDraftId(steps),
    stepId: step.id,
    name: name?.trim() || `Step ${position}`,
    instructions: null,
    position,
    required: true,
    createdAt: now(),
    updatedAt: now(),
  };
}

const CONFIG_KEYS = {
  inherit_all_project_resources: 'inheritAllProjectResources',
  base_tool_ids: 'baseToolIds',
  base_skill_ids: 'baseSkillIds',
  base_mcp_server_ids: 'baseMCPServerIds',
  base_asset_ids: 'baseAssetIds',
  base_repository_ids: 'baseRepositoryIds',
  base_config_item_ids: 'baseConfigItemIds',
} as const satisfies Record<string, keyof Workflow>;

/** How the Save payload, Run after and `@` references name a step: its id, or `new-<n>` until it is saved. */
export const stepKey = (id: number) => (isDraftId(id) ? `new${id}` : String(id));

interface Point {
  x: number;
  y: number;
}

/** Whole numbers only: Ruby and JS round a negative .5 in opposite directions, so the server must never have to round. */
const roundedPosition = (p: Point | null | undefined) => (p ? { x: Math.round(p.x), y: Math.round(p.y) } : p);

const bySubPosition = (a: SubStep, b: SubStep) => a.position - b.position;

/** The Save request body: fields, config, and every step in order with its sub-steps. */
export function aggregatePayload(workflow: Workflow, sortedSteps: Step[]) {
  return {
    name: workflow.name,
    description: workflow.description ?? '',
    runnerId: workflow.runnerId ?? null,
    budgetCents: sanitizeCapCents(workflow.budgetCents),
    config: Object.fromEntries(Object.entries(CONFIG_KEYS).map(([key, field]) => [key, workflow[field]])),
    steps: sortedSteps.map((step) => ({
      id: isDraftId(step.id) ? null : step.id,
      key: stepKey(step.id),
      name: step.name,
      instructions: step.instructions,
      kind: step.kind,
      kindConfig: step.kindConfig,
      canvasPosition: roundedPosition(step.canvasPosition),
      composite: step.composite ?? null,
      budgetCents: step.kind === 'agent' || step.kind === 'action' ? sanitizeCapCents(step.budgetCents) : null,
      agentId: step.agentId,
      allowNonInteractive: step.allowNonInteractive,
      skipPolicy: step.skipPolicy,
      onFailure: step.onFailure,
      maxRetries: step.maxRetries,
      bmadEnabled: step.bmadEnabled,
      requiredAgentRuntime: step.requiredAgentRuntime,
      preferredModel: step.preferredModel,
      reasoningEffort: step.reasoningEffort,
      inputAssetSpecs: step.inputAssetSpecs,
      outputAssetSpecs: step.outputAssetSpecs,
      toolIds: step.toolIds,
      mcpServerIds: step.mcpServerIds,
      skillIds: step.skillIds,
      assetIds: step.assetIds,
      repositoryIds: step.repositoryIds,
      configItemIds: step.configItemIds,
      dependsOnStepIds: step.dependsOnStepIds.map(stepKey),
      subSteps: [...step.subSteps].sort(bySubPosition).map((sub) => ({
        id: isDraftId(sub.id) ? null : sub.id,
        name: sub.name,
        instructions: sub.instructions,
        required: sub.required,
      })),
    })),
  };
}

/** A stable string of everything the Save sends: equal strings mean nothing to save. */
export function snapshotOf(workflow: Workflow, steps: Step[]): string {
  const sorted = [...steps].sort((a, b) => a.position - b.position);
  return JSON.stringify(aggregatePayload(workflow, sorted));
}

/** The steps with `stepId` also running after `dependencyId`; `null` for itself, an existing dependency, or one that would close a cycle. */
export function withDependency(steps: Step[], stepId: number, dependencyId: number): Step[] | null {
  const step = steps.find((s) => s.id === stepId);
  if (!step || dependencyId === stepId || step.dependsOnStepIds.includes(dependencyId)) return null;
  if (downstreamIds(steps, stepId).has(dependencyId)) return null;
  return steps.map((s) => (s.id === stepId ? { ...s, dependsOnStepIds: [...s.dependsOnStepIds, dependencyId] } : s));
}

export function withoutDependency(steps: Step[], stepId: number, dependencyId: number): Step[] {
  return steps.map((s) =>
    s.id === stepId && s.dependsOnStepIds.includes(dependencyId)
      ? { ...s, dependsOnStepIds: s.dependsOnStepIds.filter((id) => id !== dependencyId) }
      : s,
  );
}

/** The steps without `stepId`, and without any dependency on it. */
export function withoutStep(steps: Step[], stepId: number): Step[] {
  const key = stepKey(stepId);
  return steps
    .filter((s) => s.id !== stepId)
    .map((s) => {
      const dependent = s.dependsOnStepIds.includes(stepId)
        ? { ...s, dependsOnStepIds: s.dependsOnStepIds.filter((id) => id !== stepId) }
        : s;
      const args = dependent.kindConfig.arguments;
      if (!args) return dependent;
      const kept = Object.entries(args).filter(([, value]) => !outputTokens(value).some((ref) => ref.stepRef === key));
      return kept.length === Object.keys(args).length
        ? dependent
        : { ...dependent, kindConfig: { ...dependent.kindConfig, arguments: Object.fromEntries(kept) } };
    });
}

/** Every output token in a string, or in the strings nested in arrays and objects, as the server scans arguments. */
export function outputTokens(value: unknown): ReturnType<typeof scanReferences> {
  if (typeof value === 'string') return scanReferences(value).filter((ref) => ref.kind === 'output');
  if (Array.isArray(value)) return value.flatMap(outputTokens);
  if (typeof value === 'object' && value !== null) return Object.values(value).flatMap(outputTokens);
  return [];
}

/** The server refuses a stored position outside this bound. */
export const CANVAS_LIMIT = 100_000;

const clamped = (p: Point): Point => ({
  x: Math.max(-CANVAS_LIMIT, Math.min(CANVAS_LIMIT, p.x)),
  y: Math.max(-CANVAS_LIMIT, Math.min(CANVAS_LIMIT, p.y)),
});

const samePoint = (a: Point | null, b: Point) => a !== null && a.x === b.x && a.y === b.y;

/** The steps at the given positions; steps already there keep their identity. */
export function withPositions(steps: Step[], positions: Map<number, Point>): Step[] {
  return steps.map((s) => {
    const wanted = positions.get(s.id);
    const p = wanted && clamped(wanted);
    return p && !samePoint(s.canvasPosition, p) ? { ...s, canvasPosition: p } : s;
  });
}

/** Stores the resolved position of every step that has none, leaving stored positions alone. */
export function pinAll(steps: Step[], resolved: Map<number, Point>): Step[] {
  return steps.map((s) => {
    const p = resolved.get(s.id);
    return s.canvasPosition || !p ? s : { ...s, canvasPosition: clamped(p) };
  });
}

/**
 * Keeps the editor on the same step or sub-step across a save that replaced draft
 * ids with real ones. The server returns steps in the order they were sent, and
 * each step's sub-steps in theirs, so position in the list identifies them.
 */
export function remapSelection(selection: Selection | null, sent: Step[], saved: Step[]): Selection | null {
  if (!selection) return null;
  const index = sent.findIndex((s) => s.id === selection.sessionId);
  const savedStep = saved[index];
  if (index < 0 || !savedStep) return null;
  if (selection.mode === 'session') return { mode: 'session', sessionId: savedStep.id };

  const sentSubs = [...sent[index].subSteps].sort(bySubPosition);
  const savedSubs = [...savedStep.subSteps].sort(bySubPosition);
  const subIndex = sentSubs.findIndex((ss) => ss.id === selection.stepId);
  const savedSub = savedSubs[subIndex];
  return savedSub
    ? { mode: 'step', sessionId: savedStep.id, stepId: savedSub.id }
    : { mode: 'session', sessionId: savedStep.id };
}
