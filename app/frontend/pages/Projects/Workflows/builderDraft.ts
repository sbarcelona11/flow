import type { Step, SubStep, Workflow } from '@/types/generated';

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
export const runsSession = (kind: StepKind) => kind === 'agent';

export const CONTROL_STEP_MAX_SECONDS = 518_400;
export const APPROVAL_DEFAULT_SECONDS = 86_400;
export const WAIT_DEFAULT_SECONDS = 3_600;

const KIND_LABELS: Record<StepKind, string> = {
  agent: 'Session',
  approval: 'Approval',
  wait: 'Wait',
  action: 'Action',
};

export function defaultKindConfig(kind: StepKind): Step['kindConfig'] {
  if (kind === 'approval') return { timeoutSeconds: APPROVAL_DEFAULT_SECONDS, onTimeout: 'fail' };
  if (kind === 'wait') return { delaySeconds: WAIT_DEFAULT_SECONDS };
  return {};
}

/** The step as another kind: control kinds run unattended and take no agent, resources, inputs, outputs, retry or skip policy. */
export function withKind(step: Step, kind: StepKind): Step {
  if (kind === step.kind) return step;
  const cleared = isControlKind(kind)
    ? {
        agentId: null,
        requiredAgentRuntime: null,
        preferredModel: null,
        reasoningEffort: null,
        allowNonInteractive: true,
        bmadEnabled: false,
        inputAssetSpecs: [],
        outputAssetSpecs: [],
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
    : {};
  return { ...step, ...cleared, kind, kindConfig: defaultKindConfig(kind) };
}

export function draftStep(steps: Step[], name: string, kind: StepKind = 'agent'): Step {
  const position = steps.length > 0 ? Math.max(...steps.map((s) => s.position)) + 1 : 1;
  return {
    id: nextDraftId(steps),
    name: name || `${KIND_LABELS[kind]} ${position}`,
    instructions: null,
    position,
    allowNonInteractive: isControlKind(kind),
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
    outputAssetSpecs: [],
    agentId: null,
    requiredAgentRuntime: null,
    toolIds: [],
    mcpServerIds: [],
    skillIds: [],
    configItemIds: [],
    assetIds: [],
    subSteps: [],
  };
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

const bySubPosition = (a: SubStep, b: SubStep) => a.position - b.position;

/** The Save request body: fields, config, and every step in order with its sub-steps. */
export function aggregatePayload(workflow: Workflow, sortedSteps: Step[]) {
  return {
    name: workflow.name,
    description: workflow.description ?? '',
    runnerId: workflow.runnerId ?? null,
    config: Object.fromEntries(Object.entries(CONFIG_KEYS).map(([key, field]) => [key, workflow[field]])),
    steps: sortedSteps.map((step) => ({
      id: isDraftId(step.id) ? null : step.id,
      key: stepKey(step.id),
      name: step.name,
      instructions: step.instructions,
      kind: step.kind,
      kindConfig: step.kindConfig,
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
