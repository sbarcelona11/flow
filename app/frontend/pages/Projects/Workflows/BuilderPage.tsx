import { arrayMove } from '@dnd-kit/sortable';
import { Head, router, usePage } from '@inertiajs/react';
import { Alert, Button, Group, Loader, Modal, SegmentedControl, Text, TextInput, Tooltip } from '@mantine/core';
import { notifications } from '@mantine/notifications';
import { IconArrowLeft, IconDeviceFloppy, IconInfoCircle, IconPlayerPlay } from '@tabler/icons-react';
import { lazy, Suspense, useCallback, useMemo, useState } from 'react';

import type {
  ConfigItemPicker,
  MCPServerPicker,
  ModuleBlock,
  Picker,
  Project,
  RunnerSummary,
  SkillPicker,
  Step,
  ToolPicker,
  Workflow,
} from '@/types/generated';

import type { AssetPickerItem } from 'shared/components/AssetPicker';
import type { ReferenceItem } from 'shared/components/ReferenceEditor/ReferenceEditor';
import { RunWorkflowDrawer } from 'shared/components/RunWorkflowDrawer';
import { HistoryButton } from 'shared/components/versions/HistoryButton';
import { ApiError, apiRequest, notifyApiFailure } from 'shared/lib/apiFetch';
import { useFeatureFlag } from 'shared/lib/hooks/useFeatureFlag';
import { useProjectPermissions } from 'shared/lib/hooks/useProjectPermissions';
import { renameOutputReferences } from 'shared/lib/references';
import type { ToolGroup } from 'shared/lib/toolPicker';
import { useUnsavedChanges } from 'shared/lib/unsaved-changes/useUnsavedChanges';
import type { TrackerOption } from 'shared/resources/triggers/trackerTrigger';
import type { ChatProviderOption } from 'shared/resources/triggers/types';
import { companyProjectAutomationsPath } from 'shared/routes';
import { UnsavedChangesNotice } from 'shared/ui/UnsavedChangesNotice';

import { persistentProjectLayout, setPageLayout } from '../ProjectLayout';

import { BaseResourcesTab } from './BaseResourcesTab';
import {
  aggregatePayload,
  draftBlockStep,
  draftStep,
  draftSubStep,
  remapSelection,
  type StepKind,
  snapshotOf,
  withApprovalBefore,
  withDependency,
  withKind,
  withoutStep,
  stepKey,
} from './builderDraft';
import classes from './BuilderPage.module.css';
import { useCanvasAnnouncer } from './canvas/useCanvasAnnouncer';
import { type IssueFix, isPlainSpecName, sessionLabel, type WorkflowIssue } from './dataFlow';
import { availableInputs, buildReferenceCatalog } from './referenceCatalog';
import { SessionTreeNav } from './SessionTreeNav';
import type { Selection } from './SessionTreeNav';
import { StepEditorArea } from './StepEditorArea';
import { TriggersTab } from './TriggersTab';
import { useActionTargets } from './useActionTargets';
import { useBlocks } from './useBlocks';
import { dataFlowKey, useWorkflowIssues } from './useWorkflowIssues';

const WorkflowCanvas = lazy(() => import('./canvas/WorkflowCanvas'));

type ProjectOrNull = Project | null;
type AssetSpec = Step['outputAssetSpecs'][number];
interface AgentModel {
  modelId: string;
  displayName: string;
  reasoningEffortLevels: string[];
}
interface AgentModelsEntry {
  agentType: string;
  models: AgentModel[];
}

interface Props {
  project: ProjectOrNull;
  workflow: Workflow;
  steps: Step[];
  agents?: Picker[];
  tools?: ToolPicker[];
  toolGroups?: ToolGroup[];
  skills?: SkillPicker[];
  mcpServers?: MCPServerPicker[];
  assets?: AssetPickerItem[];
  repositories?: Picker[];
  configItems?: ConfigItemPicker[];
  agentModels?: AgentModelsEntry[];
  runners?: RunnerSummary[];
  readOnly: boolean;
  configuredAgents: string[];
  defaultAgentRuntime?: string | null;
  boardColumns?: { id: number; name: string; boundWorkflowName?: string | null }[];
  trackers?: TrackerOption[];
  chatProviders?: ChatProviderOption[];
  /** Data-flow issues of the saved workflow; absent from a server that predates the check. */
  issues?: WorkflowIssue[];
}

interface AggregateResponse {
  workflow: Workflow;
  steps: Step[];
  currentVersionNumber: number;
  versionCreated: boolean;
  // Optional for one release: a pod still on the previous version answers without it.
  issues?: WorkflowIssue[];
}

const BuilderPage = () => {
  const {
    project,
    workflow: initialWorkflow,
    steps: initialSteps,
    agents: rawAgents,
    tools: rawTools,
    toolGroups: rawToolGroups,
    skills: rawSkills,
    mcpServers: rawMcpServers,
    assets: rawAssets,
    repositories: rawRepositories,
    configItems: rawConfigItems,
    agentModels: rawAgentModels,
    runners: rawRunners,
    readOnly,
    configuredAgents,
    defaultAgentRuntime,
    boardColumns,
    trackers,
    chatProviders,
    issues: initialIssues,
  } = usePage<{ props: Props }>().props as unknown as Props;
  const { canExecute } = useProjectPermissions();

  const agents = rawAgents ?? [];
  const toolGroups = rawToolGroups ?? [];
  // Memoized: the reference catalog is rebuilt from these, and deferred props start out undefined.
  const tools = useMemo(() => rawTools ?? [], [rawTools]);
  const skills = useMemo(() => rawSkills ?? [], [rawSkills]);
  const mcpServers = useMemo(() => rawMcpServers ?? [], [rawMcpServers]);
  const assets = useMemo(() => rawAssets ?? [], [rawAssets]);
  const configItems = useMemo(() => rawConfigItems ?? [], [rawConfigItems]);
  const repositories = rawRepositories ?? [];
  const agentModels = rawAgentModels ?? [];
  const runners = rawRunners ?? [];
  const catalogLoading = [rawAssets, rawMcpServers, rawTools, rawSkills, rawConfigItems].some((p) => p === undefined);

  const projectId = project?.id ?? null;
  const archived = initialWorkflow.archivedAt != null;
  const backPath = projectId
    ? `/company/projects/${projectId}/workflows${archived ? '?view=archived' : ''}`
    : '/company/projects';

  const [workflow, setWorkflow] = useState(initialWorkflow);
  const [steps, setSteps] = useState(initialSteps);
  // What the server holds: the editor is dirty while its state differs from this.
  const [savedSnapshot, setSavedSnapshot] = useState(() => snapshotOf(initialWorkflow, initialSteps));
  const [saving, setSaving] = useState(false);
  // The Trackers and Triggers pages link straight to a workflow's triggers.
  const [activeTab, setActiveTab] = useState<string>(() =>
    new URLSearchParams(window.location.search).get('tab') === 'triggers' ? 'triggers' : 'sessions',
  );
  const [selection, setSelection] = useState<Selection | null>(() =>
    initialSteps.length > 0 ? { mode: 'session', sessionId: initialSteps[0].id } : null,
  );
  const [deleteStepConfirm, setDeleteStepConfirm] = useState<number | null>(null);
  const [runModalOpen, setRunModalOpen] = useState(false);

  const canvasEnabled = useFeatureFlag('automationsCanvas');
  const [view, setView] = useState<'list' | 'canvas'>(() =>
    new URLSearchParams(window.location.search).get('view') === 'canvas' ? 'canvas' : 'list',
  );
  const canvasView = canvasEnabled && view === 'canvas';
  const backToAutomations = canvasView && !archived && projectId != null;
  // The query is rewritten in place: an Inertia visit would reload the page props under the draft.
  const changeView = useCallback((next: 'list' | 'canvas') => {
    setView(next);
    const url = new URL(window.location.href);
    if (next === 'canvas') url.searchParams.set('view', 'canvas');
    else url.searchParams.delete('view');
    window.history.replaceState(window.history.state, '', url);
  }, []);

  const { message: announcement, announce } = useCanvasAnnouncer();
  const [canvasFocus, setCanvasFocus] = useState(0);

  const actionsEnabled = useFeatureFlag('workflowActionSteps');
  const actionTargets = useActionTargets(projectId, actionsEnabled && steps.some((s) => s.kind === 'action'));

  const [blocksWanted, setBlocksWanted] = useState(false);
  const wantBlocks = useCallback(() => setBlocksWanted(true), []);
  const blocks = useBlocks(projectId, actionsEnabled && (blocksWanted || steps.some((s) => s.kindConfig.block)));

  const sortedSteps = useMemo(() => [...steps].sort((a, b) => a.position - b.position), [steps]);
  const dirty = !readOnly && snapshotOf(workflow, steps) !== savedSnapshot;
  const { issues, replaceIssues } = useWorkflowIssues({ projectId, workflow, sortedSteps, initialIssues });

  // Run button guard (AC10)
  const canRun = useMemo(() => steps.some((s) => (s.instructions ?? '').trim().length > 0), [steps]);

  const updateWorkflowField = useCallback((field: string, value: unknown) => {
    setWorkflow((w) => ({ ...w, [field]: value }));
  }, []);

  // --- Session (Step) editing: local until Save ---
  const createSession = useCallback(
    (name: string, kind: StepKind = 'agent') => {
      const step = draftStep(steps, name, kind);
      setSteps([...steps, step]);
      setSelection({ mode: 'session', sessionId: step.id });
    },
    [steps],
  );

  const createBlockSession = useCallback(
    (block: ModuleBlock) => {
      const step = draftBlockStep(steps, block);
      setSteps([...steps, step]);
      setSelection({ mode: 'session', sessionId: step.id });
    },
    [steps],
  );

  const deleteSession = useCallback(
    (stepId: number) => {
      announce(`${sessionLabel(sortedSteps, stepId)} removed`);
      setCanvasFocus((n) => n + 1);
      setSteps((prev) => withoutStep(prev, stepId));
      if (selection?.sessionId === stepId) setSelection(null);
      setDeleteStepConfirm(null);
    },
    [selection, sortedSteps, announce],
  );

  const selectSession = useCallback((stepId: number | null) => {
    setSelection((current) =>
      stepId == null ? null : current?.sessionId === stepId ? current : { mode: 'session', sessionId: stepId },
    );
  }, []);

  const reorderSessions = useCallback(
    (oldIndex: number, newIndex: number) => {
      const reordered = arrayMove(sortedSteps, oldIndex, newIndex);
      setSteps(reordered.map((s, i) => ({ ...s, position: i + 1 })));
    },
    [sortedSteps],
  );

  const addApprovalBefore = useCallback(
    (actionId: number) => {
      const result = withApprovalBefore(steps, actionId);
      if (result) setSteps(result.steps);
    },
    [steps],
  );

  const changeStepKind = useCallback((stepId: number, kind: StepKind) => {
    setSteps((prev) => prev.map((s) => (s.id === stepId ? withKind(s, kind) : s)));
  }, []);

  const updateStepField = useCallback((stepId: number, field: string, value: unknown) => {
    setSteps((prev) => prev.map((s) => (s.id === stepId ? { ...s, [field]: value } : s)));
  }, []);

  // --- Sub-step management ---
  const addSubStep = useCallback(
    (sessionId: number, stepName?: string) => {
      const step = steps.find((s) => s.id === sessionId);
      if (!step) return;
      const sub = draftSubStep(steps, step, stepName);
      setSteps(steps.map((s) => (s.id === sessionId ? { ...s, subSteps: [...s.subSteps, sub] } : s)));
      setSelection({ mode: 'step', sessionId, stepId: sub.id });
    },
    [steps],
  );

  const removeSubStep = useCallback(
    (sessionId: number, subStepId: number) => {
      setSteps((prev) =>
        prev.map((s) => (s.id === sessionId ? { ...s, subSteps: s.subSteps.filter((ss) => ss.id !== subStepId) } : s)),
      );
      if (selection?.mode === 'step' && selection.stepId === subStepId) {
        setSelection({ mode: 'session', sessionId });
      }
    },
    [selection],
  );

  const handleSubStepFieldChange = useCallback(
    (sessionId: number, subStepId: number, field: string, value: unknown) => {
      setSteps((prev) =>
        prev.map((s) =>
          s.id === sessionId
            ? { ...s, subSteps: s.subSteps.map((ss) => (ss.id === subStepId ? { ...ss, [field]: value } : ss)) }
            : s,
        ),
      );
    },
    [],
  );

  const reorderSubSteps = useCallback((sessionId: number, oldIndex: number, newIndex: number) => {
    setSteps((prev) =>
      prev.map((s) => {
        if (s.id !== sessionId) return s;
        const sorted = [...s.subSteps].sort((a, b) => a.position - b.position);
        return { ...s, subSteps: arrayMove(sorted, oldIndex, newIndex).map((ss, i) => ({ ...ss, position: i + 1 })) };
      }),
    );
  }, []);

  const handleAssetSpecsChange = useCallback(
    (stepId: number, field: 'inputAssetSpecs' | 'outputAssetSpecs', specs: AssetSpec[]) => {
      setSteps((prev) => prev.map((s) => (s.id === stepId ? { ...s, [field]: specs } : s)));
    },
    [],
  );

  // A renamed output keeps every `@` reference to it, in every session.
  const renameOutput = useCallback((stepId: number, before: string, after: string) => {
    if (!isPlainSpecName(before) || !isPlainSpecName(after)) return;
    setSteps((prev) =>
      prev.map((s) =>
        s.instructions
          ? { ...s, instructions: renameOutputReferences(s.instructions, stepKey(stepId), before, after) }
          : s,
      ),
    );
  }, []);

  const stepByKey = useCallback((key: string) => steps.find((s) => stepKey(s.id) === key) ?? null, [steps]);

  // What inserting a reference, or a fix offered by the check, changes so the reference works at run time.
  const applyFix = useCallback(
    (stepId: number, fix: IssueFix) => {
      const session = steps.find((s) => s.id === stepId);
      if (!session) return;
      if (fix.kind === 'attach_asset') {
        if (!session.assetIds.includes(fix.assetId))
          updateStepField(stepId, 'assetIds', [...session.assetIds, fix.assetId]);
      } else if (fix.kind === 'attach_mcp_server') {
        if (!session.mcpServerIds.includes(fix.mcpServerId))
          updateStepField(stepId, 'mcpServerIds', [...session.mcpServerIds, fix.mcpServerId]);
      } else if (fix.kind === 'attach_tool') {
        if (!session.toolIds.includes(fix.toolId)) updateStepField(stepId, 'toolIds', [...session.toolIds, fix.toolId]);
      } else if (fix.kind === 'attach_skill') {
        if (!session.skillIds.includes(fix.skillId))
          updateStepField(stepId, 'skillIds', [...session.skillIds, fix.skillId]);
      } else if (fix.kind === 'attach_config_item') {
        if (!session.configItemIds.includes(fix.configItemId))
          updateStepField(stepId, 'configItemIds', [...session.configItemIds, fix.configItemId]);
      } else {
        const dependency = stepByKey(fix.stepKey);
        if (!dependency) return;
        if (!withDependency(steps, stepId, dependency.id)) return;
        setSteps((prev) => withDependency(prev, stepId, dependency.id) ?? prev);
        notifications.show({
          color: 'blue',
          message: `${sessionLabel(sortedSteps, stepId)} now runs after ${sessionLabel(sortedSteps, dependency.id)}`,
        });
      }
    },
    [steps, sortedSteps, stepByKey, updateStepField],
  );

  const fixLabel = useCallback(
    (fix: IssueFix): string | null => {
      if (fix.kind === 'attach_asset') {
        const asset = assets.find((a) => a.id === fix.assetId);
        return asset ? `Attach ${asset.name}` : null;
      }
      if (fix.kind === 'attach_mcp_server') {
        const server = mcpServers.find((m) => m.id === fix.mcpServerId);
        return server ? `Attach ${server.name}` : null;
      }
      if (fix.kind === 'attach_tool') {
        const tool = tools.find((t) => t.id === fix.toolId);
        return tool ? `Attach ${tool.name}` : null;
      }
      if (fix.kind === 'attach_skill') {
        const skill = skills.find((sk) => sk.id === fix.skillId);
        return skill ? `Attach ${skill.name}` : null;
      }
      if (fix.kind === 'attach_config_item') {
        const configItem = configItems.find((c) => c.id === fix.configItemId);
        return configItem ? `Attach ${configItem.name}` : null;
      }
      const dependency = stepByKey(fix.stepKey);
      return dependency ? `Run after ${sessionLabel(sortedSteps, dependency.id)}` : null;
    },
    [assets, mcpServers, tools, skills, configItems, sortedSteps, stepByKey],
  );

  const problemCounts = useMemo(() => {
    const counts: Record<number, number> = {};
    for (const issue of issues) {
      if (issue.severity !== 'error') continue;
      const step = stepByKey(issue.stepKey);
      if (step) counts[step.id] = (counts[step.id] ?? 0) + 1;
    }
    return counts;
  }, [issues, stepByKey]);

  // --- Save: the whole workflow, one request, one version ---
  const save = useCallback(async () => {
    if (projectId == null) return false;
    setSaving(true);
    try {
      const result = await apiRequest<AggregateResponse>(
        `/api/v1/projects/${projectId}/workflows/${workflow.id}/aggregate`,
        {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            baseVersion: workflow.currentVersionNumber,
            aggregate: aggregatePayload(workflow, sortedSteps),
          }),
        },
      );
      setSelection((current) => remapSelection(current, sortedSteps, result.steps));
      setWorkflow(result.workflow);
      setSteps(result.steps);
      setSavedSnapshot(snapshotOf(result.workflow, result.steps));
      if (result.issues) {
        const savedSteps = [...result.steps].sort((a, b) => a.position - b.position);
        replaceIssues(result.issues, dataFlowKey(result.workflow, savedSteps));
      }
      notifications.show({
        color: 'green',
        message: result.versionCreated ? `Saved as version ${result.currentVersionNumber}` : 'Nothing to save',
      });
      return true;
    } catch (error) {
      if (error instanceof ApiError && error.status === 409) {
        notifications.show({
          color: 'red',
          autoClose: false,
          message: `${error.message} Your edits are still here — copy what you need, then reload.`,
        });
      } else {
        notifyApiFailure(error, 'The workflow was not saved');
      }
      return false;
    } finally {
      setSaving(false);
    }
  }, [projectId, workflow, sortedSteps, replaceIssues]);
  useUnsavedChanges({ dirty, saving, onSave: save });

  // Derive selected session and step from selection state
  const selectedSession = useMemo(
    () => (selection ? (steps.find((s) => s.id === selection.sessionId) ?? null) : null),
    [steps, selection],
  );

  const referenceCatalog = useMemo(
    () =>
      selectedSession
        ? buildReferenceCatalog({
            sessionId: selectedSession.id,
            steps: sortedSteps,
            workflow,
            assets,
            mcpServers,
            tools,
            skills,
            configItems,
          })
        : { items: [] as ReferenceItem[], bindings: new Map<string, IssueFix>() },
    [selectedSession, sortedSteps, workflow, assets, mcpServers, tools, skills, configItems],
  );
  const references = useMemo(
    () => ({ items: referenceCatalog.items, loading: catalogLoading }),
    [referenceCatalog, catalogLoading],
  );
  const sessionInputs = useMemo(
    () =>
      selectedSession ? availableInputs({ sessionId: selectedSession.id, steps: sortedSteps, workflow, assets }) : [],
    [selectedSession, sortedSteps, workflow, assets],
  );
  const sessionIssues = useMemo(
    () => (selectedSession ? issues.filter((issue) => issue.stepKey === stepKey(selectedSession.id)) : []),
    [issues, selectedSession],
  );

  const selectedSubStep = useMemo(() => {
    if (!selection || selection.mode !== 'step' || !selectedSession) return null;
    return selectedSession.subSteps.find((ss) => ss.id === selection.stepId) ?? null;
  }, [selection, selectedSession]);

  return (
    <>
      <Head title={project ? `${workflow.name} — ${project.name}` : `${workflow.name}`} />

      <div className={classes.builderLayout}>
        {readOnly && (
          <Alert
            icon={<IconInfoCircle size={16} />}
            color="blue"
            radius={0}
            style={{ flexShrink: 0, borderBottom: '1px solid var(--app-border-default)' }}
          >
            {archived
              ? 'This workflow is archived, so it is read-only. Restore it from the Archived list to edit it.'
              : project && !canExecute
                ? 'You have view access to this project, so its workflows are read-only.'
                : 'This is a company-level workflow. Copy it to your project to customize.'}
          </Alert>
        )}

        {/* ===== HEADER (AC3) ===== */}
        <div className={classes.builderHeader}>
          {/* The visible title is an editable input, so the document outline
              needs its own h1 — without it the builder has no heading at all. */}
          <h1 className="app-visually-hidden">{workflow.name || 'Untitled workflow'}</h1>
          {/* Row 1: back link | spacer | save chip | run button */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10 }}>
            <button
              type="button"
              onClick={() => router.visit(backToAutomations ? companyProjectAutomationsPath(projectId) : backPath)}
              style={{
                display: 'inline-flex',
                alignItems: 'center',
                gap: 5,
                color: 'var(--text-3)',
                fontSize: 12,
                cursor: 'pointer',
                padding: '3px 6px',
                borderRadius: 4,
                border: '1px solid transparent',
                background: 'transparent',
                transition: 'all 0.12s',
                fontFamily: 'inherit',
              }}
              onMouseEnter={(e) => {
                const b = e.currentTarget;
                b.style.background = 'var(--border-mid, rgba(57,56,55,0.5))';
                b.style.borderColor = 'var(--border)';
                b.style.color = 'var(--text-2)';
              }}
              onMouseLeave={(e) => {
                const b = e.currentTarget;
                b.style.background = 'transparent';
                b.style.borderColor = 'transparent';
                b.style.color = 'var(--text-3)';
              }}
            >
              <IconArrowLeft size={13} /> {backToAutomations ? 'Automations' : 'Workflows'}
            </button>
            <div style={{ flex: 1 }} />
            <UnsavedChangesNotice visible={dirty} />
            {project && (
              <HistoryButton
                projectId={project.id}
                versionableType="Workflow"
                versionableId={workflow.id}
                title={workflow.name}
                canRevert={!readOnly}
                // The editor holds a local draft seeded from the page's props; a plain
                // reload would refresh the props under it and leave the draft as it was.
                onReverted={() => router.visit(window.location.pathname, { preserveState: false })}
              />
            )}
            {project && !readOnly && (
              <Button
                size="compact-sm"
                leftSection={<IconDeviceFloppy size={14} />}
                disabled={!dirty}
                loading={saving}
                onClick={() => void save()}
              >
                Save
              </Button>
            )}
            {project && !readOnly && (
              <Tooltip
                label={
                  dirty
                    ? 'Save first — a run uses the saved workflow'
                    : 'Add instructions to at least one session to run'
                }
                disabled={canRun && !dirty}
              >
                <button
                  type="button"
                  disabled={!canRun || dirty}
                  onClick={() => setRunModalOpen(true)}
                  style={{
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: 4,
                    padding: '4px 12px',
                    borderRadius: 4,
                    fontFamily: 'inherit',
                    fontSize: 12,
                    fontWeight: 600,
                    cursor: canRun && !dirty ? 'pointer' : 'not-allowed',
                    border: canRun && !dirty ? '1px solid var(--accent-muted)' : '1px solid var(--border)',
                    background: canRun && !dirty ? 'var(--accent-dim)' : 'var(--bg-card)',
                    color: canRun && !dirty ? 'var(--accent-text)' : 'var(--text-3)',
                    marginLeft: 8,
                    transition: 'background 0.12s, border-color 0.12s',
                  }}
                >
                  <IconPlayerPlay size={12} /> Run
                </button>
              </Tooltip>
            )}
          </div>

          {/* Row 2: editable title + scope tag */}
          <div style={{ display: 'flex', alignItems: 'flex-start' }}>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 2 }}>
                {readOnly ? (
                  <span
                    style={{
                      fontSize: 18,
                      fontWeight: 700,
                      color: 'var(--text-1)',
                      letterSpacing: '-0.02em',
                    }}
                  >
                    {workflow.name}
                  </span>
                ) : (
                  <TextInput
                    value={workflow.name}
                    onChange={(e) => updateWorkflowField('name', e.currentTarget.value)}
                    variant="unstyled"
                    classNames={{ input: classes.headerNameInput }}
                    placeholder="Workflow name…"
                    aria-label="Workflow name"
                  />
                )}
                <span
                  style={{
                    fontSize: 10,
                    fontWeight: 600,
                    letterSpacing: '0.05em',
                    textTransform: 'uppercase',
                    padding: '2px 8px',
                    borderRadius: 4,
                    border: '1px solid var(--border)',
                    background: 'var(--bg-card)',
                    color: 'var(--text-2)',
                    flexShrink: 0,
                    whiteSpace: 'nowrap',
                    lineHeight: 1.5,
                  }}
                >
                  {workflow.scopeIndicator}
                </span>
              </div>
              {/* Row 3: editable description */}
              {readOnly ? (
                workflow.description && (
                  <p style={{ margin: 0, fontSize: 13, color: 'var(--text-2)', lineHeight: 1.5 }}>
                    {workflow.description}
                  </p>
                )
              ) : (
                <textarea
                  value={workflow.description ?? ''}
                  onChange={(e) => updateWorkflowField('description', e.currentTarget.value)}
                  placeholder="Add a description…"
                  aria-label="Workflow description"
                  rows={1}
                  className={classes.headerDescInput}
                />
              )}
            </div>
          </div>
        </div>

        {/* ===== TAB BAR (AC4) ===== */}
        <div className={classes.builderTabBar}>
          {(['sessions', 'triggers', 'base-resources'] as const).map((tab) => (
            <button
              key={tab}
              type="button"
              className={`${classes.builderTab} ${activeTab === tab ? classes.builderTabActive : ''}`}
              onClick={() => setActiveTab(tab)}
            >
              {tab === 'sessions' ? 'Sessions' : tab === 'triggers' ? 'Triggers' : 'Base Resources'}
            </button>
          ))}
        </div>

        {/* ===== TAB CONTENT ===== */}
        <div className={classes.builderTabContent}>
          {/* Sessions Tab (AC5) */}
          {activeTab === 'sessions' && (
            <div className={classes.sessionsTab}>
              {canvasEnabled && (
                <div className={classes.viewBar}>
                  <SegmentedControl
                    size="xs"
                    aria-label="Sessions view"
                    value={canvasView ? 'canvas' : 'list'}
                    onChange={(value) => changeView(value === 'canvas' ? 'canvas' : 'list')}
                    data={[
                      { value: 'list', label: 'List' },
                      { value: 'canvas', label: 'Canvas' },
                    ]}
                  />
                </div>
              )}
              <div className={classes.sessionsLayout}>
                {canvasView ? (
                  <div className={classes.canvasPane}>
                    <Suspense fallback={<Loader size="sm" m="md" role="status" aria-label="Loading the canvas" />}>
                      <WorkflowCanvas
                        steps={sortedSteps}
                        issues={issues}
                        blocks={blocks.blocks}
                        blocksStatus={blocks.status}
                        actionsEnabled={actionsEnabled}
                        onWantBlocks={wantBlocks}
                        selection={selection}
                        readOnly={readOnly}
                        onSelect={selectSession}
                        onStepsChange={setSteps}
                        onRequestDelete={setDeleteStepConfirm}
                        announce={announce}
                        focusSignal={canvasFocus}
                      />
                    </Suspense>
                    <div role="status" aria-live="polite" className="app-visually-hidden">
                      {announcement}
                    </div>
                  </div>
                ) : (
                  <SessionTreeNav
                    steps={sortedSteps}
                    selection={selection}
                    readOnly={readOnly}
                    onSelectSession={(id) => setSelection({ mode: 'session', sessionId: id })}
                    onSelectStep={(sessionId, stepId) => setSelection({ mode: 'step', sessionId, stepId })}
                    onDeleteSession={(id) => setDeleteStepConfirm(id)}
                    onDeleteStep={removeSubStep}
                    onAddSession={createSession}
                    actionsEnabled={actionsEnabled}
                    blocks={blocks}
                    onWantBlocks={wantBlocks}
                    onAddBlock={createBlockSession}
                    onAddStep={addSubStep}
                    onReorderSessions={reorderSessions}
                    onReorderSteps={reorderSubSteps}
                    problemCounts={problemCounts}
                  />
                )}

                <div className={canvasView ? classes.canvasEditor : classes.editorSlot}>
                  <StepEditorArea
                    stepCount={steps.length}
                    sortedSteps={sortedSteps}
                    selection={selection}
                    selectedSession={selectedSession}
                    selectedSubStep={selectedSubStep}
                    agents={agents}
                    tools={tools}
                    toolGroups={toolGroups}
                    skills={skills}
                    mcpServers={mcpServers}
                    assets={assets}
                    repositories={repositories}
                    configItems={configItems}
                    agentModels={agentModels}
                    readOnly={readOnly}
                    references={references}
                    onInsertReference={(item) => {
                      const binding = referenceCatalog.bindings.get(item.token);
                      if (binding && selectedSession) applyFix(selectedSession.id, binding);
                    }}
                    issues={sessionIssues}
                    fixLabel={fixLabel}
                    available={sessionInputs}
                    actionsEnabled={actionsEnabled}
                    actionTargets={actionTargets}
                    blocks={blocks}
                    projectId={projectId}
                    onStepFieldChange={updateStepField}
                    onKindChange={changeStepKind}
                    onAssetSpecsChange={handleAssetSpecsChange}
                    onFix={applyFix}
                    onOutputRenamed={renameOutput}
                    onAddApprovalBefore={addApprovalBefore}
                    onSubStepFieldChange={handleSubStepFieldChange}
                  />
                </div>
              </div>
            </div>
          )}

          {/* Triggers Tab (AC6) */}
          {activeTab === 'triggers' && project && (
            <TriggersTab
              projectId={project.id}
              workflowId={workflow.id}
              columns={boardColumns ?? []}
              trackers={trackers ?? []}
              chatProviders={chatProviders ?? []}
              readOnly={readOnly}
            />
          )}

          {/* Base Resources Tab (AC7) */}
          {activeTab === 'base-resources' && (
            <BaseResourcesTab
              workflow={workflow}
              tools={tools}
              toolGroups={toolGroups}
              skills={skills}
              mcpServers={mcpServers}
              assets={assets}
              repositories={repositories}
              configItems={configItems}
              runners={runners}
              readOnly={readOnly}
              onWorkflowChange={updateWorkflowField}
            />
          )}
        </div>
      </div>

      {/* Delete session confirmation */}
      <Modal
        opened={deleteStepConfirm !== null}
        onClose={() => setDeleteStepConfirm(null)}
        title="Remove Session"
        returnFocus={!canvasView}
        centered
        size="sm"
      >
        <Text size="sm" mb="md">
          Remove {deleteStepConfirm !== null ? `“${sessionLabel(sortedSteps, deleteStepConfirm)}”` : 'this session'}? It
          goes when you save, and stays in the workflow&apos;s history.
        </Text>
        <Group justify="flex-end">
          <Button variant="outline" onClick={() => setDeleteStepConfirm(null)}>
            Cancel
          </Button>
          <Button color="red" onClick={() => deleteStepConfirm !== null && deleteSession(deleteStepConfirm)}>
            Remove
          </Button>
        </Group>
      </Modal>

      {project && (
        <RunWorkflowDrawer
          opened={runModalOpen}
          onClose={() => setRunModalOpen(false)}
          workflows={[
            {
              id: workflow.id,
              name: workflow.name,
              runnerId: workflow.runnerId ?? null,
              steps: steps.map((s) => ({
                id: s.id,
                name: s.name,
                position: s.position,
                kind: s.kind,
                allowNonInteractive: s.allowNonInteractive,
                dependsOnStepIds: s.dependsOnStepIds,
              })),
            },
          ]}
          initialWorkflowId={workflow.id}
          projectId={project.id}
          configuredAgents={configuredAgents}
          defaultAgentRuntime={defaultAgentRuntime}
          agentModels={agentModels}
          repositories={repositories}
          assets={assets}
          runners={runners}
        />
      )}
    </>
  );
};

setPageLayout(BuilderPage, persistentProjectLayout);

export default BuilderPage;
