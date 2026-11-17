import '@testing-library/jest-dom/vitest';
import { acceptCompletion, currentCompletions, setSelectedCompletion, startCompletion } from '@codemirror/autocomplete';
import { EditorView } from '@codemirror/view';
import { router } from '@inertiajs/react';
import { notifications } from '@mantine/notifications';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { buildAssetPicker } from 'test/factories/assetPicker';
import { buildRunnerSummary } from 'test/factories/runner';
import { answerFetch } from 'test/fetchStub';
import { visitHeld } from 'test/inertiaVisit';
import { act, renderAuthedPage, screen, userEvent, waitFor, within } from 'test/renderPage';

import type { aggregatePayload } from './builderDraft';
import BuilderPage from './BuilderPage';

// --- Inline fixtures (structurally match the page's Props/Step/Workflow shapes) ---

const makeStep = (overrides: Record<string, unknown> = {}) => ({
  id: 1,
  name: 'Draft spec',
  instructions: null,
  position: 1,
  kind: 'agent',
  kindConfig: {} as Record<string, unknown>,
  agentId: null,
  requiredAgentRuntime: null,
  preferredModel: null,
  reasoningEffort: null,
  allowNonInteractive: false,
  skipPolicy: 'never',
  onFailure: 'fail',
  maxRetries: 0,
  bmadEnabled: false,
  dependsOnStepIds: [] as number[],
  toolIds: [] as number[],
  mcpServerIds: [] as number[],
  skillIds: [] as number[],
  assetIds: [] as number[],
  repositoryIds: [] as number[],
  configItemIds: [] as number[],
  inputAssetSpecs: [] as { name: string; assetType: string; required: boolean; namePattern?: string | null }[],
  outputAssetSpecs: [] as { name: string; assetType: string; required: boolean; namePattern?: string | null }[],
  subSteps: [] as {
    id: number;
    name: string;
    instructions: string | null;
    position: number;
    required: boolean;
  }[],
  ...overrides,
});

const makeWorkflow = (overrides: Record<string, unknown> = {}) => ({
  id: 3,
  name: 'Release pipeline',
  description: null,
  scopeType: 'project',
  scopeIndicator: 'Project',
  currentVersionNumber: 1,
  inheritAllProjectResources: false,
  baseToolIds: [] as number[],
  baseSkillIds: [] as number[],
  baseMCPServerIds: [] as number[],
  baseAssetIds: [] as number[],
  baseRepositoryIds: [] as number[],
  baseConfigItemIds: [] as number[],
  ...overrides,
});

const projectProps = (overrides: Record<string, unknown> = {}) => ({
  project: { id: 7, name: 'Apollo' },
  workflow: makeWorkflow(),
  steps: [makeStep({ id: 1, name: 'Draft spec', position: 1 }), makeStep({ id: 2, name: 'Implement', position: 2 })],
  agents: [],
  tools: [],
  toolGroups: [],
  skills: [],
  mcpServers: [],
  assets: [],
  repositories: [],
  configItems: [],
  agentModels: [],
  readOnly: false,
  configuredAgents: [] as string[],
  // The saved workflow's data-flow issues; with them the page does not ask for a check on load.
  issues: [] as unknown[],
  ...overrides,
});

// --- Save: PUT …/aggregate, answered with the saved state the way the server echoes it ---

const SAVE_ROUTE = 'PUT /api/v1/projects/7/workflows/3/aggregate';
const CHECK_ROUTE = 'POST /api/v1/projects/7/workflows/3/aggregate/check';

type Aggregate = ReturnType<typeof aggregatePayload>;
interface SaveBody {
  baseVersion: number;
  aggregate: Aggregate;
}

const CONFIG_FIELDS: Record<string, string> = {
  inherit_all_project_resources: 'inheritAllProjectResources',
  base_tool_ids: 'baseToolIds',
  base_skill_ids: 'baseSkillIds',
  base_mcp_server_ids: 'baseMCPServerIds',
  base_asset_ids: 'baseAssetIds',
  base_repository_ids: 'baseRepositoryIds',
  base_config_item_ids: 'baseConfigItemIds',
};

function savedState({ aggregate }: SaveBody, workflow: ReturnType<typeof makeWorkflow>) {
  const idByKey = new Map(aggregate.steps.map((step, i) => [step.key, step.id ?? 100 + i]));
  const steps = aggregate.steps.map(({ key, dependsOnStepIds, subSteps, ...fields }, i) =>
    makeStep({
      ...fields,
      id: idByKey.get(key),
      position: i + 1,
      dependsOnStepIds: dependsOnStepIds.map((depKey) => idByKey.get(depKey)),
      subSteps: subSteps.map((sub, j) => ({ ...sub, id: sub.id ?? 1000 + 10 * i + j, position: j + 1 })),
    }),
  );
  const config = Object.fromEntries(
    Object.entries(aggregate.config).map(([key, value]) => [CONFIG_FIELDS[key], value]),
  );
  return {
    workflow: {
      ...workflow,
      name: aggregate.name,
      description: aggregate.description,
      runnerId: aggregate.runnerId,
      ...config,
      currentVersionNumber: 2,
    },
    steps,
    currentVersionNumber: 2,
    versionCreated: true,
    issues: [],
  };
}

/**
 * Answers the Save request, recording each body it was sent, and the data-flow check an edit to
 * instructions, dependencies, assets or specs sends a moment later.
 */
function answerSave(workflow = makeWorkflow(), issues: unknown[] = []) {
  const bodies: SaveBody[] = [];
  const checks: { aggregate: Aggregate }[] = [];
  const fetchSpy = answerFetch({
    [SAVE_ROUTE]: (init?: RequestInit) => {
      const body = JSON.parse(String(init?.body)) as SaveBody;
      bodies.push(body);
      return savedState(body, workflow);
    },
    [CHECK_ROUTE]: (init?: RequestInit) => {
      checks.push(JSON.parse(String(init?.body)) as { aggregate: Aggregate });
      return { issues };
    },
  });
  return { fetchSpy, bodies, checks };
}

/** Clicks Save and returns the aggregate it sent. */
async function save(bodies: SaveBody[]): Promise<Aggregate> {
  await userEvent.click(screen.getByRole('button', { name: 'Save' }));
  await waitFor(() => expect(bodies).toHaveLength(1));
  return bodies[0].aggregate;
}

// An edit to the data flow asks for a check a moment later; tests that answer other requests
// replace this with answerSave() or their own answerFetch().
beforeEach(() => {
  answerFetch({ [CHECK_ROUTE]: { issues: [] } });
});

afterEach(() => {
  vi.restoreAllMocks();
  notifications.clean();
});

// Model options as the server sends them, each with the levels its runtime takes for it.
const KIRO_MODELS = [
  {
    agentType: 'kiro_cli',
    models: [
      {
        modelId: 'claude-opus-5.5',
        displayName: 'Opus 5.5',
        reasoningEffortLevels: ['low', 'medium', 'high', 'xhigh', 'max'],
      },
      {
        modelId: 'claude-sonnet-4.6',
        displayName: 'Sonnet 4.6',
        reasoningEffortLevels: ['low', 'medium', 'high', 'max'],
      },
    ],
  },
];

describe('Projects/Workflows/BuilderPage', () => {
  it('renders the sessions sidebar and the first session selected in the detail panel', () => {
    renderAuthedPage(<BuilderPage />, { props: projectProps() });

    // Sessions tab is active.
    expect(screen.getByRole('button', { name: 'Sessions' })).toBeInTheDocument();

    // Both sessions listed in the sidebar.
    expect(screen.getAllByText('Draft spec').length).toBeGreaterThan(0);
    expect(screen.getByText('Implement')).toBeInTheDocument();

    // First session is auto-selected: its Name field is populated in the detail panel.
    expect(screen.getByDisplayValue('Draft spec')).toBeInTheDocument();

    // Run button is present because a project is set.
    expect(screen.getByRole('button', { name: 'Run' })).toBeInTheDocument();
  });

  it('shows the empty state when there are no sessions', () => {
    renderAuthedPage(<BuilderPage />, { props: projectProps({ steps: [] }) });

    expect(screen.getByText('No sessions yet')).toBeInTheDocument();
  });

  it('selecting a different step swaps the detail panel to that step', async () => {
    renderAuthedPage(<BuilderPage />, { props: projectProps() });

    // Initially the first step's name is the editable Name input value.
    expect(screen.getByDisplayValue('Draft spec')).toBeInTheDocument();
    expect(screen.queryByDisplayValue('Implement')).not.toBeInTheDocument();

    // Click the second step card in the sidebar.
    await userEvent.click(screen.getByText('Implement'));

    expect(screen.getByDisplayValue('Implement')).toBeInTheDocument();
  });

  it('asks before leaving over unsaved edits, and saves on Save before going', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, { props: projectProps({ steps: [] }) });
    expect(visitHeld('/company/projects/7/workflows')).toBe(false);

    await userEvent.click(screen.getByText('Add a session…'));
    await userEvent.type(screen.getByPlaceholderText('Session name…'), 'My session{Enter}');
    expect(visitHeld('/company/projects/7/workflows')).toBe(true);

    const question = await screen.findByRole('dialog', { name: 'Save your changes?' });
    await userEvent.click(within(question).getByRole('button', { name: 'Save' }));

    await waitFor(() => expect(bodies).toHaveLength(1));
    await waitFor(() =>
      expect(router.visit).toHaveBeenCalledWith(
        new URL('/company/projects/7/workflows', window.location.origin).href,
        expect.anything(),
      ),
    );
  });

  it('a session added from the ghost row is sent on Save as a new step and shows under its saved name', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, { props: projectProps({ steps: [] }) });

    // The "Add a session…" ghost row is a div, not a button — click it to start.
    await userEvent.click(screen.getByText('Add a session…'));
    await userEvent.type(screen.getByPlaceholderText('Session name…'), 'My session{Enter}');
    expect(bodies).toHaveLength(0);

    const aggregate = await save(bodies);

    expect(aggregate.steps).toHaveLength(1);
    expect(aggregate.steps[0]).toMatchObject({ id: null, name: 'My session' });
    expect(aggregate.steps[0].key).toMatch(/^new/);
    expect(await screen.findByDisplayValue('My session')).toBeInTheDocument();
    expect(screen.getByText('My session')).toBeInTheDocument();
  });

  it('a new session that an existing session depends on is sent with the dependency as the new step key', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ steps: [makeStep({ id: 1, name: 'Draft spec', position: 1 })] }),
    });

    // The ghost row focuses its input; the detail panel holds a second "Session name…" field.
    await userEvent.click(screen.getByText('Add a session…'));
    await userEvent.keyboard('Research{Enter}');

    // Back on the existing session, make it wait for the new one.
    await userEvent.click(screen.getByText('Draft spec'));
    await userEvent.click(screen.getByPlaceholderText('Select sessions this session depends on…'));
    await userEvent.click(await screen.findByRole('option', { name: '2. Research' }));

    const aggregate = await save(bodies);

    const [existing, added] = aggregate.steps;
    expect(added).toMatchObject({ id: null, name: 'Research' });
    expect(existing).toMatchObject({ id: 1, dependsOnStepIds: [added.key] });
    expect(await screen.findByText(/↳ AFTER\s*Research/)).toBeInTheDocument();
  });

  it('adding an Approval creates a step with kind approval and a 24 hour timeout', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, { props: projectProps({ steps: [] }) });

    await userEvent.click(screen.getByRole('button', { name: 'Add an approval' }));

    expect(screen.getByLabelText('Expires after (hours)')).toHaveValue('24');
    const aggregate = await save(bodies);
    expect(aggregate.steps[0]).toMatchObject({
      kind: 'approval',
      kindConfig: { timeoutSeconds: 86400, onTimeout: 'fail' },
      agentId: null,
      allowNonInteractive: true,
      outputAssetSpecs: [],
    });
  });

  it('an approval step hides the agent and output fields', async () => {
    renderAuthedPage(<BuilderPage />, { props: projectProps({ steps: [] }) });

    await userEvent.click(screen.getByRole('button', { name: 'Add an approval' }));

    expect(screen.getByLabelText('Expires after (hours)')).toBeInTheDocument();
    expect(screen.getByText('If no one decides')).toBeInTheDocument();
    expect(screen.queryByLabelText('Agent')).not.toBeInTheDocument();
    expect(screen.queryByLabelText('Required agent runtime')).not.toBeInTheDocument();
    expect(screen.queryByLabelText('Tools')).not.toBeInTheDocument();
    expect(screen.queryByText('Output artifact')).not.toBeInTheDocument();
    expect(screen.queryByText('On Failure')).not.toBeInTheDocument();
    expect(screen.queryByText('Skip Policy')).not.toBeInTheDocument();
  });

  it('an approval saves the chosen timeout in seconds and the skip outcome', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, { props: projectProps({ steps: [] }) });

    await userEvent.click(screen.getByRole('button', { name: 'Add an approval' }));
    const hours = screen.getByLabelText('Expires after (hours)');
    await userEvent.clear(hours);
    await userEvent.type(hours, '2');
    await userEvent.click(screen.getByRole('combobox', { name: 'If no one decides' }));
    await userEvent.click(await screen.findByRole('option', { name: 'Skip' }));

    const aggregate = await save(bodies);
    expect(aggregate.steps[0].kindConfig).toEqual({ timeoutSeconds: 7200, onTimeout: 'skip' });
  });

  it('a wait step saves until_context_key and drops delay_seconds when switched', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, { props: projectProps({ steps: [] }) });

    await userEvent.click(screen.getByRole('button', { name: 'Add a wait' }));
    expect(screen.getByLabelText('Hours')).toHaveValue('1');

    await userEvent.click(screen.getByRole('radio', { name: 'Until the time in shared context key' }));
    await userEvent.type(screen.getByLabelText('Shared context key'), 'release.go_live_at');

    const aggregate = await save(bodies);
    expect(aggregate.steps[0]).toMatchObject({ kind: 'wait', kindConfig: { untilContextKey: 'release.go_live_at' } });
    expect(aggregate.steps[0].kindConfig).not.toHaveProperty('delaySeconds');
  });

  it('a wait duration is saved in seconds and capped at 144 hours', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, { props: projectProps({ steps: [] }) });

    await userEvent.click(screen.getByRole('button', { name: 'Add a wait' }));
    const hours = screen.getByLabelText('Hours');
    await userEvent.clear(hours);
    await userEvent.type(hours, '999');
    await userEvent.click(screen.getByLabelText('Minutes'));

    const aggregate = await save(bodies);
    expect(aggregate.steps[0].kindConfig).toEqual({ delaySeconds: 518400 });
  });

  it('a wait duration keeps an emptied field empty while typing', async () => {
    renderAuthedPage(<BuilderPage />, { props: projectProps({ steps: [] }) });

    await userEvent.click(screen.getByRole('button', { name: 'Add a wait' }));
    await userEvent.clear(screen.getByLabelText('Hours'));

    expect(screen.getByLabelText('Hours')).toHaveValue('');
    expect(screen.getByLabelText('Minutes')).toHaveValue('0');
  });

  it('a wait duration left empty saves and shows the one-minute minimum once the field is left', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, { props: projectProps({ steps: [] }) });

    await userEvent.click(screen.getByRole('button', { name: 'Add a wait' }));
    await userEvent.clear(screen.getByLabelText('Hours'));
    await userEvent.clear(screen.getByLabelText('Minutes'));
    await userEvent.click(screen.getByLabelText('Hours'));

    expect(screen.getByLabelText('Minutes')).toHaveValue('1');
    const aggregate = await save(bodies);
    expect(aggregate.steps[0].kindConfig).toEqual({ delaySeconds: 60 });
  });

  it('a wait of 144 hours shows and saves zero minutes', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, { props: projectProps({ steps: [] }) });

    await userEvent.click(screen.getByRole('button', { name: 'Add a wait' }));
    const minutes = screen.getByLabelText('Minutes');
    await userEvent.clear(minutes);
    await userEvent.type(minutes, '30');
    const hours = screen.getByLabelText('Hours');
    await userEvent.clear(hours);
    await userEvent.type(hours, '144');

    expect(screen.getByLabelText('Minutes')).toHaveValue('0');
    expect(screen.getByLabelText('Minutes')).toBeDisabled();
    const aggregate = await save(bodies);
    expect(aggregate.steps[0].kindConfig).toEqual({ delaySeconds: 518400 });
  });

  it('switching an agent session to an approval clears its agent-only fields', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({
            id: 1,
            agentId: 5,
            requiredAgentRuntime: 'kiro_cli',
            preferredModel: 'claude-opus-5.5',
            reasoningEffort: 'high',
            onFailure: 'retry',
            maxRetries: 2,
            skipPolicy: 'manual',
            outputAssetSpecs: [{ name: 'report.md', assetType: 'file', required: true }],
            inputAssetSpecs: [{ name: 'brief.md', assetType: 'file', required: true }],
            toolIds: [3],
            skillIds: [4],
            mcpServerIds: [6],
            assetIds: [8],
            repositoryIds: [9],
            configItemIds: [10],
            bmadEnabled: true,
            allowNonInteractive: false,
          }),
        ],
        agents: [{ id: 5, name: 'Builder' }],
      }),
    });

    await userEvent.click(screen.getByRole('combobox', { name: 'Step type' }));
    await userEvent.click(await screen.findByRole('option', { name: 'Approval' }));

    const aggregate = await save(bodies);
    expect(aggregate.steps[0]).toMatchObject({
      kind: 'approval',
      kindConfig: { timeoutSeconds: 86400, onTimeout: 'fail' },
      agentId: null,
      requiredAgentRuntime: null,
      preferredModel: null,
      reasoningEffort: null,
      onFailure: 'fail',
      maxRetries: 0,
      skipPolicy: 'never',
      outputAssetSpecs: [],
      inputAssetSpecs: [],
      toolIds: [],
      skillIds: [],
      mcpServerIds: [],
      assetIds: [],
      repositoryIds: [],
      configItemIds: [],
      bmadEnabled: false,
      allowNonInteractive: true,
    });
  });

  it('a step with no kind still shows the agent fields', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ steps: [makeStep({ id: 1, name: 'Draft spec', kind: undefined })] }),
    });

    expect(screen.getByRole('combobox', { name: 'Agent' })).toBeInTheDocument();
    expect(screen.queryByLabelText('Expires after (hours)')).not.toBeInTheDocument();
  });

  it('the session tree marks approval and wait steps', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({ id: 1, name: 'Draft spec', position: 1 }),
          makeStep({ id: 2, name: 'Sign off', position: 2, kind: 'approval' }),
          makeStep({ id: 3, name: 'Cool down', position: 3, kind: 'wait' }),
        ],
      }),
    });

    expect(within(screen.getByText('Sign off').parentElement!).getByText('Approval')).toBeInTheDocument();
    expect(within(screen.getByText('Cool down').parentElement!).getByText('Wait')).toBeInTheDocument();
    expect(within(screen.getByText('Draft spec').parentElement!).queryByText('Approval')).not.toBeInTheDocument();
  });

  it('renders a read-only company workflow without editing affordances', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        project: null,
        readOnly: true,
        workflow: makeWorkflow({ name: 'Company onboarding', scopeIndicator: 'Company' }),
      }),
    });

    // Company-level read-only banner.
    expect(
      screen.getByText('This is a company-level workflow. Copy it to your project to customize.'),
    ).toBeInTheDocument();

    // Name renders as static text (not an editable input) and there is no Run affordance (no project).
    expect(screen.getByRole('heading', { level: 1, name: 'Company onboarding' })).toBeInTheDocument();
    expect(screen.queryByDisplayValue('Company onboarding')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Run' })).not.toBeInTheDocument();
  });

  it('renders status badges (AUTO / BMAD / runtime) for a session in the sidebar', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({
            id: 1,
            name: 'Draft spec',
            position: 1,
            allowNonInteractive: true,
            bmadEnabled: true,
            requiredAgentRuntime: 'claude_code',
          }),
        ],
      }),
    });

    expect(screen.getByText('AUTO')).toBeInTheDocument();
    expect(screen.getByText('BMAD')).toBeInTheDocument();
    // Runtime value is mapped to its human label (badge + the detail-panel Select option both show it).
    expect(screen.getAllByText('Claude Code').length).toBeGreaterThan(0);
  });

  it('the BMAD "Learn more" link points to the BMAD docs and opens in a new tab', async () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, bmadEnabled: false })] }),
    });

    const link = screen.getByRole('link', { name: /Learn more/ });
    expect(link).toHaveAttribute('href', 'https://docs.bmad-method.org/');
    expect(link).toHaveAttribute('target', '_blank');
    expect(link).toHaveAttribute('rel', 'noopener noreferrer');

    // Toggling the BMAD Method switch must not change the link.
    // The BMAD switch lives in the same row (togRow) as the "BMAD Method" label.
    const bmadLabel = screen.getByText('BMAD Method');
    const bmadRow = bmadLabel.parentElement?.parentElement as HTMLElement;
    const bmadSwitch = within(bmadRow).getByRole('switch');
    await userEvent.click(bmadSwitch);

    const linkAfter = screen.getByRole('link', { name: /Learn more/ });
    expect(linkAfter).toHaveAttribute('href', 'https://docs.bmad-method.org/');
    expect(linkAfter).toHaveAttribute('target', '_blank');
    expect(linkAfter).toHaveAttribute('rel', 'noopener noreferrer');
  });

  it('marks a session with no dependencies as "ROOT" and a dependent session with an "↳ AFTER" badge', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({ id: 1, name: 'Draft spec', position: 1, dependsOnStepIds: [] }),
          makeStep({ id: 2, name: 'Implement', position: 2, dependsOnStepIds: [1] }),
        ],
      }),
    });

    // Session 1 (root) gets a ROOT badge; session 2 references its dependency by name.
    expect(screen.getByText('ROOT')).toBeInTheDocument();
    expect(screen.getByText(/↳ AFTER\s*Draft spec/)).toBeInTheDocument();
  });

  it('shows the assigned agent name under a step card in the sidebar', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        agents: [{ id: 42, name: 'Builder Bot' }],
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, agentId: 42 })],
      }),
    });

    // Sidebar card sub-label + the Agent <Select> option both surface the name.
    expect(screen.getAllByText('Builder Bot').length).toBeGreaterThan(0);
  });

  it('removing a session through the modal drops it, and the dependencies on it, from the Save', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({ id: 1, name: 'Draft spec', position: 1 }),
          makeStep({ id: 2, name: 'Implement', position: 2, dependsOnStepIds: [1] }),
        ],
      }),
    });

    await userEvent.click(screen.getByRole('button', { name: 'Delete session "Draft spec"' }));
    expect(await screen.findByRole('dialog', { name: 'Remove Session' })).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Remove' }));

    await waitFor(() => expect(screen.queryByRole('dialog', { name: 'Remove Session' })).not.toBeInTheDocument());
    expect(screen.queryByText('Draft spec')).not.toBeInTheDocument();
    expect(bodies).toHaveLength(0);

    const aggregate = await save(bodies);

    expect(aggregate.steps).toHaveLength(1);
    expect(aggregate.steps[0]).toMatchObject({ id: 2, name: 'Implement', dependsOnStepIds: [] });
  });

  it('cancelling the remove-session modal closes it and keeps the session', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch');

    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ steps: [makeStep({ id: 1, name: 'Draft spec', position: 1 })] }),
    });

    await userEvent.click(screen.getByRole('button', { name: 'Delete session "Draft spec"' }));
    expect(await screen.findByRole('dialog', { name: 'Remove Session' })).toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Cancel' }));

    await waitFor(() => expect(screen.queryByRole('dialog', { name: 'Remove Session' })).not.toBeInTheDocument());
    expect(screen.getByDisplayValue('Draft spec')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled();
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('a config item attached to a step is sent in its configItemIds on Save', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1 })],
        configItems: [
          { id: 11, name: 'STRIPE_KEY', itemType: 'secret' },
          { id: 12, name: 'API_BASE', itemType: 'variable' },
        ],
      }),
    });

    await userEvent.click(screen.getByRole('combobox', { name: /secrets and variables/i }));
    await userEvent.click(await screen.findByText('STRIPE_KEY (secret)'));
    expect(bodies).toHaveLength(0);

    const aggregate = await save(bodies);

    expect(aggregate.steps[0].configItemIds).toEqual([11]);
  });

  it('renders drag handles for sessions in the tree nav', () => {
    renderAuthedPage(<BuilderPage />, { props: projectProps() });

    // Both sessions have drag handles in the tree nav.
    const dragHandles = screen.getAllByTitle(/Drag to reorder session/);
    expect(dragHandles.length).toBe(2);
  });

  it('renders the session tree nav with both sessions', () => {
    renderAuthedPage(<BuilderPage />, { props: projectProps() });

    // Both session names appear in the tree nav.
    expect(screen.getAllByText('Draft spec').length).toBeGreaterThan(0);
    expect(screen.getByText('Implement')).toBeInTheDocument();
  });

  it('opening the Run drawer shows it titled for the workflow', async () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, instructions: 'Do the thing' })],
      }),
    });

    await userEvent.click(screen.getByRole('button', { name: 'Run' }));

    const drawer = await screen.findByRole('dialog');
    expect(drawer.textContent).toMatch(/Run:.*Release pipeline/);
    expect(screen.getByText('Execution mode')).toBeInTheDocument();
  });

  it('disables the Run button when no session has instructions', () => {
    renderAuthedPage(<BuilderPage />, { props: projectProps() });

    // Default makeStep has no instructions, so Run should be disabled.
    expect(screen.getByRole('button', { name: 'Run' })).toBeDisabled();
  });

  it('an edited session name is sent on Save', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ steps: [makeStep({ id: 1, name: 'Draft spec', position: 1 })] }),
    });

    await userEvent.type(screen.getByRole('textbox', { name: 'Session name' }), '!');
    expect(bodies).toHaveLength(0);

    const aggregate = await save(bodies);

    expect(aggregate.steps[0]).toMatchObject({ id: 1, key: '1', name: 'Draft spec!' });
  });

  it('an edit shows the unsaved-changes notice until Save succeeds, then reports the new version', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, instructions: 'Do the thing' })],
      }),
    });

    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled();
    expect(screen.queryByText('Unsaved changes — press Save to keep them')).not.toBeInTheDocument();

    await userEvent.type(screen.getByRole('textbox', { name: 'Session name' }), '!');

    expect(screen.getByText('Unsaved changes — press Save to keep them')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Save' })).toBeEnabled();
    // A run uses the saved workflow, so it waits for the save.
    expect(screen.getByRole('button', { name: 'Run' })).toBeDisabled();

    const aggregate = await save(bodies);

    expect(bodies[0].baseVersion).toBe(1);
    expect(aggregate.steps[0].name).toBe('Draft spec!');
    expect(await screen.findByText('Saved as version 2')).toBeInTheDocument();
    expect(screen.queryByText('Unsaved changes — press Save to keep them')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Run' })).toBeEnabled();
  });

  it('a Save refused with a conflict keeps the edit on screen and says how to recover it', async () => {
    answerFetch({
      [SAVE_ROUTE]: new Response(
        JSON.stringify({
          error: 'Someone else saved a newer version (v2). Reload to see their changes before saving.',
          currentVersionNumber: 2,
        }),
        { status: 409, headers: { 'Content-Type': 'application/json' } },
      ),
    });
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ steps: [makeStep({ id: 1, name: 'Draft spec', position: 1 })] }),
    });

    await userEvent.type(screen.getByRole('textbox', { name: 'Session name' }), '!');
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));

    expect(
      await screen.findByText(
        'Someone else saved a newer version (v2). Reload to see their changes before saving. Your edits are still here — copy what you need, then reload.',
      ),
    ).toBeInTheDocument();
    expect(screen.getByDisplayValue('Draft spec!')).toBeInTheDocument();
    expect(screen.getByText('Unsaved changes — press Save to keep them')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Save' })).toBeEnabled();
  });

  it('the chosen agent is sent in the step agentId on Save', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        agents: [{ id: 42, name: 'Builder Bot' }],
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, agentId: null })],
      }),
    });

    await userEvent.click(screen.getByRole('combobox', { name: 'Agent' }));
    await userEvent.click(await screen.findByRole('option', { name: 'Builder Bot' }));
    expect(bodies).toHaveLength(0);

    const aggregate = await save(bodies);

    expect(aggregate.steps[0].agentId).toBe(42);
  });

  it('shows the On Failure select in the Behavior section', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, onFailure: 'retry' })],
      }),
    });

    // On Failure select is visible in the Behavior section.
    expect(screen.getByText('Behavior')).toBeInTheDocument();
  });

  it('shows the On Failure select defaulting to Fail', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, onFailure: 'fail' })] }),
    });

    // Behavior section is always visible.
    expect(screen.getByText('Behavior')).toBeInTheDocument();
  });

  it('adds an asset spec row when "+ Add input" is clicked in the Data Flow section', async () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ steps: [makeStep({ id: 1, name: 'Draft spec', position: 1 })] }),
    });

    // The Data Flow section is always visible; "None added" is shown by default.
    expect(screen.getAllByText('None added').length).toBeGreaterThan(0);

    // Click the "+ Add input" button to add an input spec.
    await userEvent.click(screen.getByRole('button', { name: '+ Add input' }));

    // A new editable path input (with the placeholder) appears.
    expect(await screen.findByPlaceholderText('e.g. report.md')).toBeInTheDocument();
  });

  it('renders sub-steps nested under a session in the tree nav', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({
            id: 1,
            name: 'Draft spec',
            position: 1,
            subSteps: [
              { id: 11, name: 'Task Alpha', instructions: null, position: 1, required: true },
              { id: 12, name: 'Task Beta', instructions: null, position: 2, required: false },
            ],
          }),
        ],
      }),
    });

    // Both sub-step names appear in the tree nav.
    expect(screen.getByText('Task Alpha')).toBeInTheDocument();
    expect(screen.getByText('Task Beta')).toBeInTheDocument();
  });

  it('shows the no-dependency helper text in the Dependencies section for a root session', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, dependsOnStepIds: [] })] }),
    });

    expect(
      screen.getByText('No dependencies — this session can run in parallel with other root sessions.'),
    ).toBeInTheDocument();
  });

  it('offers a tool group as a section whose members open individually', async () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        tools: [
          { id: 10, name: 'Board List Tasks' },
          { id: 11, name: 'Board Move Task' },
          { id: 20, name: 'Echo Greeter' },
        ],
        toolGroups: [{ tag: 'board', label: 'Board management', toolIds: [10, 11] }],
        workflow: makeWorkflow({ inheritAllProjectResources: false }),
      }),
    });

    // Open the session-level Tools picker (first "None added" field in the Resources section).
    await userEvent.click(screen.getAllByPlaceholderText('None added')[0]);

    // The group shows as a section header; its members stay folded away until asked for.
    expect(await screen.findByRole('checkbox', { name: /Board management/ })).toBeInTheDocument();
    expect(screen.queryByRole('option', { name: 'Board List Tasks' })).not.toBeInTheDocument();
    // Ungrouped custom tool stays individual.
    expect(screen.getByRole('option', { name: 'Echo Greeter' })).toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Expand Board management' }));

    expect(screen.getByRole('option', { name: 'Board List Tasks' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Board Move Task' })).toBeInTheDocument();
  });

  it('renders the workflow scope indicator badge in the header', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ workflow: makeWorkflow({ scopeIndicator: 'Project' }) }),
    });

    // The scope indicator is shown as a badge next to the title.
    expect(screen.getByText('Project')).toBeInTheDocument();
  });

  it('opening the Triggers tab reveals the triggers content', async () => {
    answerFetch({ 'GET /api/v1/projects/7/workflows/:workflow/triggers': { triggers: [] } });
    renderAuthedPage(<BuilderPage />, { props: projectProps() });

    // Tab is not active initially — triggers content not visible.
    expect(screen.queryByText(/how this workflow launches/)).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Triggers' }));

    // The TriggersTab heading appears (text is split across elements).
    expect(await screen.findByText('Triggers', { selector: 'div' })).toBeInTheDocument();
    expect(await screen.findByText(/how this workflow launches/)).toBeInTheDocument();
  });

  it('an edited workflow name is sent on Save', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, { props: projectProps() });

    await userEvent.type(screen.getByRole('textbox', { name: 'Workflow name' }), '!');
    expect(bodies).toHaveLength(0);

    const aggregate = await save(bodies);

    expect(aggregate.name).toBe('Release pipeline!');
    expect(await screen.findByDisplayValue('Release pipeline!')).toBeInTheDocument();
  });

  it('an edited workflow description is sent on Save', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, { props: projectProps() });

    await userEvent.type(screen.getByPlaceholderText('Add a description…'), 'Ship');
    expect(bodies).toHaveLength(0);

    const aggregate = await save(bodies);

    expect(aggregate.description).toBe('Ship');
  });

  it('toggling "Inherit all project resources" shows the helper text and is sent in the config on Save', async () => {
    const workflow = makeWorkflow({ inheritAllProjectResources: false });
    const { bodies } = answerSave(workflow);
    renderAuthedPage(<BuilderPage />, { props: projectProps({ workflow }) });

    // Navigate to the Base Resources tab, then flip the inherit switch.
    await userEvent.click(screen.getByRole('button', { name: /Base Resources/ }));
    await userEvent.click(await screen.findByRole('switch'));

    expect(
      await screen.findByText(/Tools, skills, MCP servers, and assets from the project level are included/),
    ).toBeInTheDocument();
    expect(bodies).toHaveLength(0);

    const aggregate = await save(bodies);

    expect(aggregate.config.inherit_all_project_resources).toBe(true);
  });

  it('attaching a base tool group from its header sends every member in base_tool_ids on Save', async () => {
    const workflow = makeWorkflow({ inheritAllProjectResources: false });
    const { bodies } = answerSave(workflow);
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        tools: [
          { id: 10, name: 'Board List Tasks' },
          { id: 11, name: 'Board Move Task' },
        ],
        toolGroups: [{ tag: 'board', label: 'Board management', toolIds: [10, 11] }],
        workflow,
      }),
    });

    await userEvent.click(screen.getByRole('button', { name: /Base Resources/ }));
    await userEvent.click(await screen.findByPlaceholderText('Select tools…'));
    await userEvent.click(await screen.findByRole('checkbox', { name: /Board management/ }));

    const aggregate = await save(bodies);

    // One click on the header attaches the whole family.
    expect(aggregate.config.base_tool_ids).toEqual([10, 11]);
  });

  it('attaching one tool out of a base group sends that id alone in base_tool_ids on Save', async () => {
    const workflow = makeWorkflow({ inheritAllProjectResources: false });
    const { bodies } = answerSave(workflow);
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        tools: [
          { id: 10, name: 'Board List Tasks' },
          { id: 11, name: 'Board Move Task' },
        ],
        toolGroups: [{ tag: 'board', label: 'Board management', toolIds: [10, 11] }],
        workflow,
      }),
    });

    await userEvent.click(screen.getByRole('button', { name: /Base Resources/ }));
    await userEvent.click(await screen.findByPlaceholderText('Select tools…'));
    await userEvent.click(await screen.findByRole('button', { name: 'Expand Board management' }));
    await userEvent.click(screen.getByRole('option', { name: 'Board Move Task' }));

    const aggregate = await save(bodies);

    // A subset stays a subset — no silent expansion to the whole group.
    expect(aggregate.config.base_tool_ids).toEqual([11]);
  });

  it('a runner picked under Base Resources is sent as runnerId on Save', async () => {
    const workflow = makeWorkflow();
    const { bodies } = answerSave(workflow);
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        workflow,
        runners: [buildRunnerSummary({ id: 4, name: 'Prod VPC' })],
        features: { externalRunners: true },
      }),
    });

    await userEvent.click(screen.getByRole('button', { name: /Base Resources/ }));
    expect(screen.getByRole('combobox', { name: 'Runner' })).toHaveDisplayValue('Hosted (default)');
    await userEvent.click(screen.getByRole('combobox', { name: 'Runner' }));
    await userEvent.click(await screen.findByRole('option', { name: 'Prod VPC · Connected' }));

    const aggregate = await save(bodies);

    expect(aggregate.runnerId).toBe(4);
  });

  it('warns about a runner that is deleted, disabled or revoked, and keeps it selected', async () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        workflow: makeWorkflow({ runnerId: 4 }),
        runners: [buildRunnerSummary({ id: 4, name: 'Old box', deleted: true })],
        features: { externalRunners: true },
      }),
    });

    await userEvent.click(screen.getByRole('button', { name: /Base Resources/ }));

    expect(screen.getByRole('combobox', { name: 'Runner' })).toHaveDisplayValue('Old box · Deleted');
    expect(screen.getByText(/Runner "Old box" is deleted\. Runs of this workflow fail/)).toBeInTheDocument();
  });

  it('shows no runner select without the flag', async () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ runners: [buildRunnerSummary({ id: 4 })] }),
    });

    await userEvent.click(screen.getByRole('button', { name: /Base Resources/ }));

    expect(screen.queryByRole('combobox', { name: 'Runner' })).not.toBeInTheDocument();
  });

  it('without the flag offers only a switch back to Hosted for a workflow that names a runner', async () => {
    const workflow = makeWorkflow({ runnerId: 4 });
    const { bodies } = answerSave(workflow);
    renderAuthedPage(<BuilderPage />, { props: projectProps({ workflow }) });

    await userEvent.click(screen.getByRole('button', { name: /Base Resources/ }));

    expect(screen.queryByRole('combobox', { name: 'Runner' })).not.toBeInTheDocument();
    expect(screen.getByText(/external runners are not enabled for this company/)).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Switch to Hosted' }));
    expect(screen.queryByText(/external runners are not enabled for this company/)).not.toBeInTheDocument();

    const aggregate = await save(bodies);

    expect(aggregate.runnerId).toBeNull();
  });

  it('a selected base repository is sent in base_repository_ids on Save', async () => {
    const workflow = makeWorkflow({ inheritAllProjectResources: false });
    const { bodies } = answerSave(workflow);
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ repositories: [{ id: 21, name: 'acme/api' }], workflow }),
    });

    await userEvent.click(screen.getByRole('button', { name: /Base Resources/ }));
    await userEvent.click(await screen.findByPlaceholderText('Select repositories…'));
    await userEvent.click((await screen.findAllByRole('option', { name: 'acme/api' }))[0]);

    const aggregate = await save(bodies);

    expect(aggregate.config.base_repository_ids).toEqual([21]);
  });

  // Repositories narrow the project-wide set rather than adding to it, so this
  // picker must stay usable when the other four are disabled by "inherit all".
  it('keeps the base repository picker enabled while "inherit all project resources" is on', async () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        repositories: [{ id: 21, name: 'acme/api' }],
        workflow: makeWorkflow({ inheritAllProjectResources: true }),
      }),
    });

    await userEvent.click(screen.getByRole('button', { name: /Base Resources/ }));

    expect(await screen.findByPlaceholderText('Select repositories…')).toBeEnabled();
    expect(screen.getByPlaceholderText('Select tools…')).toBeDisabled();
  });

  it('a repository selected on a session is sent in the step repositoryIds on Save', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        repositories: [{ id: 21, name: 'acme/api' }],
        steps: [makeStep({ id: 1, name: 'Implement' })],
      }),
    });

    await userEvent.click(await screen.findByText('Implement'));
    // Mantine puts the aria-label on both the search input and the hidden value input.
    await userEvent.click((await screen.findAllByLabelText('Repositories'))[0]);
    await userEvent.click((await screen.findAllByRole('option', { name: 'acme/api' }))[0]);

    const aggregate = await save(bodies);

    expect(aggregate.steps[0].repositoryIds).toEqual([21]);
  });

  it('an asset selected on a session is sent in the step assetIds on Save', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        assets: [{ id: 31, name: 'brand-guide.pdf' }],
        steps: [makeStep({ id: 1, name: 'Implement' })],
      }),
    });

    await userEvent.click(await screen.findByText('Implement'));
    await userEvent.click((await screen.findAllByLabelText('Assets'))[0]);
    await userEvent.click((await screen.findAllByRole('option', { name: 'brand-guide.pdf' }))[0]);

    const aggregate = await save(bodies);

    expect(aggregate.steps[0].assetIds).toEqual([31]);
  });

  it('toggling "Auto-run available" surfaces the "AUTO" badge and is sent on Save', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, allowNonInteractive: false })],
      }),
    });

    // With no asset specs, the first switch on the session panel is "Auto-run available".
    await userEvent.click(screen.getAllByRole('switch')[0]);

    expect(await screen.findByText('AUTO')).toBeInTheDocument();
    expect(bodies).toHaveLength(0);

    const aggregate = await save(bodies);

    expect(aggregate.steps[0].allowNonInteractive).toBe(true);
    expect(screen.getByText('AUTO')).toBeInTheDocument();
  });

  it('setting On Failure to "Retry" asks for a retry count from one, and both are sent on Save', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, onFailure: 'fail', maxRetries: 0 })],
      }),
    });

    expect(screen.queryByRole('combobox', { name: 'Max retries' })).not.toBeInTheDocument();

    // The On Failure select has no accessible name; it is the combobox currently showing "Fail".
    const onFailureCombobox = screen.getAllByRole('combobox').find((cb) => cb.getAttribute('value') === 'Fail');
    await userEvent.click(onFailureCombobox!);
    await userEvent.click(await screen.findByRole('option', { name: 'Retry' }));

    const maxRetries = screen.getByRole('combobox', { name: 'Max retries' });
    expect(maxRetries).toHaveValue('1');
    await userEvent.click(maxRetries);
    await userEvent.click(await screen.findByRole('option', { name: '3' }));

    const aggregate = await save(bodies);

    expect(aggregate.steps[0]).toMatchObject({ onFailure: 'retry', maxRetries: 3 });
  });

  it('choosing an Execution Environment sends the runtime and a cleared preferredModel on Save', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({
            id: 1,
            name: 'Draft spec',
            position: 1,
            requiredAgentRuntime: 'claude_code',
            preferredModel: 'opus-9',
          }),
        ],
        agentModels: [
          {
            agentType: 'claude_code',
            models: [{ modelId: 'opus-9', displayName: 'Opus 9', reasoningEffortLevels: [] }],
          },
        ],
      }),
    });

    await userEvent.click(screen.getByRole('combobox', { name: 'Required agent runtime' }));
    await userEvent.click(await screen.findByRole('option', { name: 'Cursor CLI' }));

    const aggregate = await save(bodies);

    expect(aggregate.steps[0]).toMatchObject({ requiredAgentRuntime: 'cursor_cli', preferredModel: null });
  });

  it('shows a step runtime set on the server without making a request', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch');

    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, requiredAgentRuntime: 'claude_code' })],
        agentModels: [
          {
            agentType: 'claude_code',
            models: [{ modelId: 'opus-9', displayName: 'Opus 9', reasoningEffortLevels: [] }],
          },
        ],
      }),
    });

    // Claude Code is shown as the runtime value.
    expect(screen.getAllByText('Claude Code').length).toBeGreaterThan(0);

    await waitFor(() => expect(fetchSpy).not.toHaveBeenCalled());
  });

  it("a Preferred Model picked from the runtime's models is sent on Save", async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, requiredAgentRuntime: 'claude_code' })],
        agentModels: [
          {
            agentType: 'claude_code',
            models: [{ modelId: 'opus-9', displayName: 'Opus 9', reasoningEffortLevels: [] }],
          },
          { agentType: 'cursor_cli', models: [{ modelId: 'gpt-x', displayName: 'GPT X', reasoningEffortLevels: [] }] },
        ],
      }),
    });

    await userEvent.click(screen.getAllByLabelText('Preferred model')[0]);
    expect(await screen.findByRole('option', { name: 'Opus 9' })).toBeInTheDocument();
    expect(screen.queryByRole('option', { name: 'GPT X' })).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole('option', { name: 'Opus 9' }));

    const aggregate = await save(bodies);

    expect(aggregate.steps[0].preferredModel).toBe('opus-9');
  });

  it("a Reasoning Effort offers the runtime's levels on a chosen model and is sent on Save", async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({
            id: 1,
            name: 'Review',
            position: 1,
            requiredAgentRuntime: 'gemini_cli',
            preferredModel: 'gemini-3-pro',
          }),
        ],
        agentModels: [
          {
            agentType: 'gemini_cli',
            models: [
              { modelId: 'gemini-3-pro', displayName: 'Gemini 3 Pro', reasoningEffortLevels: ['low', 'high'] },
              { modelId: 'gemini-2.5-pro', displayName: 'Gemini 2.5 Pro', reasoningEffortLevels: [] },
            ],
          },
        ],
      }),
    });

    expect(screen.getByText("The CLI may lower or ignore a level the model doesn't support.")).toBeInTheDocument();
    await userEvent.click(screen.getByRole('combobox', { name: 'Reasoning effort' }));
    expect(await screen.findByRole('option', { name: 'Low' })).toBeInTheDocument();
    expect(screen.queryByRole('option', { name: 'Medium' })).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole('option', { name: 'High' }));

    const aggregate = await save(bodies);

    expect(aggregate.steps[0].reasoningEffort).toBe('high');
  });

  it('a Reasoning Effort is disabled, with the reason, where the runtime and model take none', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({
            id: 1,
            name: 'Review',
            position: 1,
            requiredAgentRuntime: 'gemini_cli',
            preferredModel: 'gemini-2.5-pro',
          }),
        ],
        agentModels: [
          {
            agentType: 'gemini_cli',
            models: [
              { modelId: 'gemini-3-pro', displayName: 'Gemini 3 Pro', reasoningEffortLevels: ['low', 'high'] },
              { modelId: 'gemini-2.5-pro', displayName: 'Gemini 2.5 Pro', reasoningEffortLevels: [] },
            ],
          },
        ],
      }),
    });

    expect(screen.getByRole('combobox', { name: 'Reasoning effort' })).toBeDisabled();
    expect(screen.getByText('Gemini CLI has no reasoning-effort setting for gemini-2.5-pro.')).toBeInTheDocument();
  });

  it('a saved level the model does not take is shown as an error, not dropped', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({
            id: 1,
            name: 'Review',
            position: 1,
            requiredAgentRuntime: 'kiro_cli',
            preferredModel: 'claude-sonnet-4.6',
            reasoningEffort: 'xhigh',
          }),
        ],
        agentModels: KIRO_MODELS,
      }),
    });

    expect(
      screen.getByText(
        'Extra high is not available for Kiro CLI with claude-sonnet-4.6. Choose one of: Low, Medium, High, Max.',
      ),
    ).toBeInTheDocument();
    await userEvent.click(screen.getByRole('textbox', { name: 'Session name' }));
    await userEvent.type(screen.getByRole('textbox', { name: 'Session name' }), ' 2');

    const aggregate = await save(bodies);

    expect(aggregate.steps[0].reasoningEffort).toBe('xhigh');
  });

  it("switching to a model that doesn't take the level clears it, and keeps one it takes", async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({
            id: 1,
            name: 'Review',
            position: 1,
            requiredAgentRuntime: 'kiro_cli',
            preferredModel: 'claude-opus-5.5',
            reasoningEffort: 'xhigh',
          }),
        ],
        agentModels: KIRO_MODELS,
      }),
    });
    const effort = () => screen.getByRole('combobox', { name: 'Reasoning effort' });
    const pickModel = async (name: string) => {
      await userEvent.click(screen.getByRole('combobox', { name: 'Preferred model' }));
      await userEvent.click(await screen.findByRole('option', { name }));
    };

    expect(effort()).toHaveValue('Extra high');
    await pickModel('Sonnet 4.6');
    expect(effort()).toHaveValue('');
    expect(screen.queryByText(/is not available for/)).not.toBeInTheDocument();

    await userEvent.click(effort());
    await userEvent.click(await screen.findByRole('option', { name: 'High' }));
    await pickModel('Opus 5.5');
    expect(effort()).toHaveValue('High');

    const aggregate = await save(bodies);

    expect(aggregate.steps[0]).toMatchObject({ preferredModel: 'claude-opus-5.5', reasoningEffort: 'high' });
  });

  it("a Reasoning Effort says the levels are unknown for a model the server doesn't list", () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({
            id: 1,
            name: 'Review',
            position: 1,
            requiredAgentRuntime: 'kiro_cli',
            preferredModel: 'claude-opus-9',
            reasoningEffort: 'high',
          }),
        ],
        agentModels: KIRO_MODELS,
      }),
    });

    expect(screen.getByRole('combobox', { name: 'Reasoning effort' })).toHaveValue('High');
    expect(
      screen.getByText("Kiro CLI doesn't list claude-opus-9, so its reasoning-effort levels are unknown."),
    ).toBeInTheDocument();
  });

  it('a Reasoning Effort is hidden while the model is left on Default', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [makeStep({ id: 1, name: 'Review', position: 1, requiredAgentRuntime: 'claude_code' })],
      }),
    });

    expect(screen.queryByRole('combobox', { name: 'Reasoning effort' })).not.toBeInTheDocument();
  });

  it('switching the runtime clears the model and the level with it', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({
            id: 1,
            name: 'Review',
            position: 1,
            requiredAgentRuntime: 'claude_code',
            preferredModel: 'claude-opus-5',
            reasoningEffort: 'max',
          }),
        ],
      }),
    });

    await userEvent.click(screen.getByRole('combobox', { name: 'Required agent runtime' }));
    await userEvent.click(await screen.findByRole('option', { name: 'Kiro CLI' }));

    expect(screen.queryByRole('combobox', { name: 'Reasoning effort' })).not.toBeInTheDocument();
    const aggregate = await save(bodies);

    expect(aggregate.steps[0]).toMatchObject({
      requiredAgentRuntime: 'kiro_cli',
      preferredModel: null,
      reasoningEffort: null,
    });
  });

  it('a selected dependency shows the "↳ AFTER" badge in the sidebar and is sent by step key on Save', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({ id: 1, name: 'Draft spec', position: 1, dependsOnStepIds: [] }),
          makeStep({ id: 2, name: 'Implement', position: 2, dependsOnStepIds: [] }),
        ],
      }),
    });

    // The Dependencies section is always visible — pick the other session.
    await userEvent.click(screen.getByPlaceholderText('Select sessions this session depends on…'));
    await userEvent.click(await screen.findByRole('option', { name: '2. Implement' }));

    // The sidebar card for session 1 now records the dependency.
    expect(await screen.findByText(/↳ AFTER\s*Implement/)).toBeInTheDocument();
    expect(bodies).toHaveLength(0);

    const aggregate = await save(bodies);

    expect(aggregate.steps[0].dependsOnStepIds).toEqual(['2']);
  });

  it('a sub-step added via the tree nav ghost row is sent as a new sub-step on Save', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, subSteps: [] })] }),
    });

    await userEvent.click(screen.getByText('Add a step…'));
    await userEvent.type(screen.getByPlaceholderText('Step name…'), 'New step{Enter}');
    expect(bodies).toHaveLength(0);

    const aggregate = await save(bodies);

    expect(aggregate.steps[0].subSteps).toEqual([{ id: null, name: 'New step', instructions: null, required: true }]);
    expect(screen.getByText('New step')).toBeInTheDocument();
  });

  it('confirming a blank step name adds nothing', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch');

    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, subSteps: [] })] }),
    });

    await userEvent.click(screen.getByText('Add a step…'));
    const ghostInput = screen.getByPlaceholderText('Step name…');
    // Whitespace-only entry is treated as empty — the ghost row just closes.
    await userEvent.type(ghostInput, '   {Enter}');

    expect(fetchSpy).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled();
  });

  it('clicking a sub-step in the tree nav opens the StepEditorPanel', async () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({
            id: 1,
            name: 'Draft spec',
            position: 1,
            subSteps: [{ id: 11, name: 'Task Alpha', instructions: null, position: 1, required: true }],
          }),
        ],
      }),
    });

    // The sub-step label "a" appears in the tree nav; click to select it.
    await userEvent.click(screen.getByText('Task Alpha'));

    // StepEditorPanel renders with the "Step name…" placeholder input.
    expect(await screen.findByPlaceholderText('Step name…')).toBeInTheDocument();
  });

  it('adding an output asset spec reveals the Match pattern input and is sent in outputAssetSpecs on Save', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ steps: [makeStep({ id: 1, name: 'Draft spec', position: 1 })] }),
    });

    await userEvent.click(screen.getByRole('button', { name: '+ Add output' }));

    // Output specs support a name pattern; the pattern input only renders there.
    expect(screen.getByPlaceholderText('e.g. report')).toBeInTheDocument();

    await userEvent.type(screen.getByPlaceholderText('e.g. report.md or reports/*.md'), 'out.md');
    expect(bodies).toHaveLength(0);

    const aggregate = await save(bodies);

    expect(aggregate.steps[0].outputAssetSpecs).toHaveLength(1);
    expect(aggregate.steps[0].outputAssetSpecs[0].name).toBe('out.md');
  });

  it('opens an archived workflow read-only and leads back to the archived list', async () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({ readOnly: true, workflow: makeWorkflow({ archivedAt: '2026-10-23T14:33:48Z' }) }),
    });

    expect(
      screen.getByText('This workflow is archived, so it is read-only. Restore it from the Archived list to edit it.'),
    ).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Save' })).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Workflows' }));
    expect(router.visit).toHaveBeenCalledWith('/company/projects/7/workflows?view=archived');
  });

  it('renders a read-only project workflow with disabled editing affordances', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        readOnly: true,
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1 })],
      }),
    });

    // Detail-panel session name input is present but disabled (no label — find by placeholder).
    expect(screen.getByPlaceholderText('Session name…')).toBeDisabled();

    // Run button is not shown in read-only mode.
    expect(screen.queryByRole('button', { name: 'Run' })).not.toBeInTheDocument();
  });

  it('reloads the page without its draft after a revert, so the editor shows the reverted workflow', async () => {
    const version = (number: number) => ({
      id: 100 + number,
      number,
      versionableType: 'Workflow',
      versionableId: 3,
      terminalSessionId: null,
      createdAt: '2026-09-25T10:00:00Z',
      event: 'saved',
      source: 'ui',
      author: { id: 1, name: 'Ada' },
      restoredFromNumber: null,
      baseline: false,
      duplicatedFromId: null,
      disabledTriggerIds: [],
    });
    answerFetch({
      'GET /api/v1/projects/7/entity_versions': {
        versions: [version(2), version(1)],
        nextBefore: null,
        currentVersionNumber: 2,
      },
      'GET /api/v1/projects/7/entity_versions/101': {
        ...version(1),
        snapshot: { name: 'Release pipeline', steps: [] },
        previousSnapshot: null,
        currentSnapshot: { name: 'Release pipeline', steps: [] },
        currentVersionNumber: 2,
        references: {},
      },
      'POST /api/v1/projects/7/entity_versions/101/revert': { ...version(3), event: 'reverted', restoredFromNumber: 1 },
    });
    renderAuthedPage(<BuilderPage />, { props: projectProps() });

    await userEvent.click(screen.getByRole('button', { name: 'History of Release pipeline' }));
    await userEvent.click(await screen.findByRole('button', { name: /v1 Saved/ }));
    await userEvent.click(await screen.findByRole('button', { name: 'Revert to v1' }));
    await userEvent.click(
      within(await screen.findByRole('dialog', { name: 'Revert to v1?' })).getByRole('button', { name: 'Revert' }),
    );

    await waitFor(() => expect(router.visit).toHaveBeenCalledWith(window.location.pathname, { preserveState: false }));
  });
});

const instructionsEditor = () => {
  const view = EditorView.findFromDOM(screen.getByRole('textbox', { name: 'Session instructions' }));
  if (!view) throw new Error('the session instructions editor is not mounted');
  return view;
};

/** Types "@<query>" at the end of the instructions and picks the row labelled `label`. */
async function pickReference(label: string, query = '') {
  const view = instructionsEditor();
  const at = view.state.doc.length;
  const text = `@${query}`;
  act(() => {
    view.dispatch({
      changes: { from: at, insert: text },
      selection: { anchor: at + text.length },
      userEvent: 'input.type',
    });
    startCompletion(view);
  });
  await waitFor(() => expect(currentCompletions(view.state).map((c) => c.label)).toContain(label));
  const index = currentCompletions(view.state).findIndex((c) => c.label === label);
  act(() => view.dispatch({ effects: setSelectedCompletion(index) }));
  // The list ignores Enter for a moment after it opens, so fast typing does not pick a row.
  await waitFor(() => {
    let accepted = false;
    act(() => {
      accepted = acceptCompletion(view);
    });
    expect(accepted).toBe(true);
  });
}

describe('Projects/Workflows/BuilderPage @ references and data-flow issues', () => {
  it('picking a project asset writes its token and attaches the asset to the session', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        assets: [buildAssetPicker({ id: 31, fileName: 'brand-guide.pdf', name: 'brand-guide.pdf' })],
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, instructions: 'Read ' })],
      }),
    });

    await pickReference('brand-guide.pdf', 'brand');

    expect(
      within(screen.getByRole('textbox', { name: 'Session instructions' })).getByText('brand-guide.pdf'),
    ).toBeInTheDocument();
    const aggregate = await save(bodies);
    expect(aggregate.steps[0]).toMatchObject({ instructions: 'Read {{asset:31}} ', assetIds: [31] });
  });

  it("picking another session's output makes this session run after it", async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({
            id: 1,
            name: 'Collect',
            position: 1,
            outputAssetSpecs: [{ name: 'summary.md', assetType: 'file', required: true, namePattern: null }],
          }),
          makeStep({ id: 2, name: 'Report', position: 2 }),
        ],
      }),
    });
    await userEvent.click(screen.getByText('Report'));

    await pickReference('summary.md', 'sum');

    expect(await screen.findByText('Report now runs after Collect')).toBeInTheDocument();
    const aggregate = await save(bodies);
    expect(aggregate.steps[1]).toMatchObject({ instructions: '{{output:1:summary.md}} ', dependsOnStepIds: ['1'] });
  });

  it('picking a tool, a skill and a config item the session lacks attaches each of them', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        tools: [{ id: 41, name: 'Post to Slack', toolName: 'slack_post', scope: 'project' }],
        skills: [{ id: 51, name: 'House style', skillName: 'house-style' }],
        configItems: [{ id: 61, name: 'STAGING_URL', itemType: 'variable', description: null }],
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, instructions: 'Use ' })],
      }),
    });

    await pickReference('Post to Slack', 'slack');
    await pickReference('House style', 'house');
    await pickReference('STAGING_URL', 'STAGING');

    const aggregate = await save(bodies);
    expect(aggregate.steps[0]).toMatchObject({
      instructions: 'Use {{tool:41}} {{skill:51}} {{config_item:61}} ',
      toolIds: [41],
      skillIds: [51],
      configItemIds: [61],
    });
  });

  it('treats an internal MCP server as attached when the workflow inherits every project resource', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        workflow: makeWorkflow({ inheritAllProjectResources: true }),
        mcpServers: [{ id: 9, name: 'aixle-tools', transport: 'http', scope: 'internal' }],
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, instructions: 'Ask ' })],
      }),
    });

    await pickReference('aixle-tools', 'aixle');

    const aggregate = await save(bodies);
    expect(aggregate.steps[0]).toMatchObject({ instructions: 'Ask {{mcp:9}} ', mcpServerIds: [] });
  });

  it('sends the unsaved draft to the check after a data-flow edit and shows what it finds', async () => {
    const warning = {
      severity: 'warning',
      code: 'step_not_upstream',
      stepKey: '1',
      field: 'instructions',
      message: 'Draft spec mentions Implement, which does not run before it.',
      fix: { kind: 'add_dependency', stepKey: '2' },
    };
    const { checks } = answerSave(makeWorkflow(), [warning]);
    renderAuthedPage(<BuilderPage />, { props: projectProps() });

    await pickReference('Implement');

    // A slow run can send a check for the bare `@` too; the one that counts carries the pick.
    await waitFor(() => expect(checks.map((check) => check.aggregate.steps[0].instructions)).toContain('{{step:2}} '), {
      timeout: 3000,
    });
    const problems = await screen.findByRole('list', { name: 'Problems in the instructions' });
    expect(within(problems).getByText(warning.message)).toBeInTheDocument();
  });

  it("shows the saved workflow's issues with their fix, and counts errors in the tree", async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        mcpServers: [{ id: 7, name: 'GitHub', transport: 'http', scope: 'project' }],
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, instructions: 'Open issues in {{mcp:7}}' })],
        issues: [
          {
            severity: 'error',
            code: 'ref_not_attached',
            stepKey: '1',
            field: 'instructions',
            message: 'Draft spec names GitHub, which this session does not receive.',
            fix: { kind: 'attach_mcp_server', mcpServerId: 7 },
          },
        ],
      }),
    });

    const problems = screen.getByRole('list', { name: 'Problems in the instructions' });
    expect(
      within(problems).getByText('Draft spec names GitHub, which this session does not receive.'),
    ).toBeInTheDocument();
    expect(screen.getByLabelText('1 problem')).toBeInTheDocument();

    await userEvent.click(within(problems).getByRole('button', { name: 'Attach GitHub' }));

    const aggregate = await save(bodies);
    expect(aggregate.steps[0].mcpServerIds).toEqual([7]);
  });

  it('a renamed output keeps the references to it, and loses a pasted container prefix', async () => {
    const { bodies } = answerSave();
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        steps: [
          makeStep({
            id: 1,
            name: 'Collect',
            position: 1,
            outputAssetSpecs: [{ name: 'summary.md', assetType: 'file', required: true, namePattern: null }],
          }),
          makeStep({
            id: 2,
            name: 'Report',
            position: 2,
            dependsOnStepIds: [1],
            instructions: 'Read {{output:1:summary.md}}',
          }),
        ],
      }),
    });

    const name = screen.getByRole('textbox', { name: 'Output 1 name' });
    await userEvent.clear(name);
    await userEvent.type(name, '/workspace/outputs/final.md');
    await userEvent.tab();

    expect(name).toHaveValue('final.md');
    const aggregate = await save(bodies);
    expect(aggregate.steps[0].outputAssetSpecs[0].name).toBe('final.md');
    expect(aggregate.steps[1].instructions).toBe('Read {{output:1:final.md}}');
  });

  it('shows a viewer the instructions with their pills, read-only and without the picker', () => {
    renderAuthedPage(<BuilderPage />, {
      props: projectProps({
        readOnly: true,
        projectPermissions: { canExecute: false, canManage: false, canManageCompany: false },
        assets: [buildAssetPicker({ id: 31, fileName: 'brand-guide.pdf', name: 'brand-guide.pdf' })],
        steps: [makeStep({ id: 1, name: 'Draft spec', position: 1, instructions: 'Read {{asset:31}}' })],
      }),
    });

    expect(
      screen.getByText('You have view access to this project, so its workflows are read-only.'),
    ).toBeInTheDocument();
    const editor = screen.getByRole('textbox', { name: 'Session instructions' });
    expect(editor).toHaveAttribute('contenteditable', 'false');
    expect(within(editor).getByText('brand-guide.pdf')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Save' })).not.toBeInTheDocument();
  });
});

describe('Projects/Workflows/BuilderPage action steps', () => {
  const TARGETS_ROUTE = 'GET /api/v1/projects/7/action_targets';

  const target = (overrides: Record<string, unknown>) => ({
    type: 'mcp_tool',
    mcpServerId: 5,
    serverName: 'Linear',
    tool: 'create_issue',
    toolId: null,
    name: 'Create issue',
    description: 'Creates an issue',
    inputSchema: {
      type: 'object',
      required: ['title'],
      properties: { title: { type: 'string' }, points: { type: 'integer' } },
    },
    baseEffect: 'write',
    drifted: false,
    ...overrides,
  });

  const TARGETS = [
    target({}),
    target({ tool: 'list_issues', name: 'List issues', baseEffect: 'read', inputSchema: {} }),
    target({ tool: 'delete_project', name: 'Delete project', baseEffect: 'irreversible', inputSchema: {} }),
    target({
      tool: 'search',
      name: 'Search',
      baseEffect: 'read',
      inputSchema: { type: 'object', properties: { pageSize: { type: 'integer' } } },
    }),
    target({ tool: 'old_tool', name: 'Old tool', drifted: true, inputSchema: {} }),
    target({
      type: 'wrapper',
      mcpServerId: null,
      serverName: null,
      tool: null,
      toolId: 9,
      name: 'Deploy',
      inputSchema: {},
    }),
  ];

  const actionProps = (overrides: Record<string, unknown> = {}) =>
    projectProps({ steps: [], features: { workflowActionSteps: true }, ...overrides });

  async function chooseTool(name: string) {
    await userEvent.click(await screen.findByRole('combobox', { name: 'Tool' }));
    await userEvent.click(await screen.findByRole('option', { name }));
  }

  async function chooseEffect(name: string) {
    await userEvent.click(screen.getByRole('combobox', { name: 'Effect' }));
    await userEvent.click(await screen.findByRole('option', { name }));
  }

  function answerTargets() {
    const bodies: SaveBody[] = [];
    answerFetch({
      [TARGETS_ROUTE]: TARGETS,
      [SAVE_ROUTE]: (init?: RequestInit) => {
        const body = JSON.parse(String(init?.body)) as SaveBody;
        bodies.push(body);
        return savedState(body, makeWorkflow());
      },
      [CHECK_ROUTE]: { issues: [] },
    });
    return { bodies };
  }

  it('adding an action saves kind action with the chosen tool and arguments', async () => {
    const { bodies } = answerTargets();
    renderAuthedPage(<BuilderPage />, { props: actionProps() });

    await userEvent.click(screen.getByRole('button', { name: 'Add an action' }));
    await chooseTool('Create issue');
    await userEvent.click(screen.getByRole('textbox', { name: 'title' }));
    await userEvent.paste('Bug {{context:issue.key}}');
    await userEvent.click(screen.getByRole('textbox', { name: 'points' }));
    await userEvent.paste('3');

    const aggregate = await save(bodies);
    expect(aggregate.steps[0]).toMatchObject({
      kind: 'action',
      kindConfig: {
        target: 'mcp_tool',
        mcpServerId: 5,
        tool: 'create_issue',
        arguments: { title: 'Bug {{context:issue.key}}', points: 3 },
        effect: 'write',
        outputName: 'result.json',
      },
      agentId: null,
      outputAssetSpecs: [{ name: 'result.json' }],
    });
  });

  it('an action shows neither the agent editor nor the approval settings', async () => {
    answerTargets();
    renderAuthedPage(<BuilderPage />, { props: actionProps() });

    await userEvent.click(screen.getByRole('button', { name: 'Add an action' }));

    expect(await screen.findByRole('combobox', { name: 'Tool' })).toBeInTheDocument();
    expect(screen.getByRole('textbox', { name: 'Output file' })).toHaveValue('result.json');
    expect(screen.queryByLabelText('Agent')).not.toBeInTheDocument();
    expect(screen.queryByText('Session instructions')).not.toBeInTheDocument();
    expect(screen.queryByLabelText('Expires after (hours)')).not.toBeInTheDocument();
    expect(screen.queryByText('AUTO')).not.toBeInTheDocument();
    expect(screen.getAllByText('Action').length).toBeGreaterThan(0);
  });

  it('saves argument names exactly as the tool names them', async () => {
    const { bodies } = answerTargets();
    renderAuthedPage(<BuilderPage />, { props: actionProps() });

    await userEvent.click(screen.getByRole('button', { name: 'Add an action' }));
    await chooseTool('Search');
    await userEvent.click(screen.getByRole('textbox', { name: 'pageSize' }));
    await userEvent.paste('25');

    const aggregate = await save(bodies);
    expect(aggregate.steps[0].kindConfig.arguments).toEqual({ pageSize: 25 });
  });

  it('a wrapper tool saves its tool id', async () => {
    const { bodies } = answerTargets();
    renderAuthedPage(<BuilderPage />, { props: actionProps() });

    await userEvent.click(screen.getByRole('button', { name: 'Add an action' }));
    await chooseTool('Deploy');

    const aggregate = await save(bodies);
    expect(aggregate.steps[0].kindConfig).toMatchObject({ target: 'wrapper', toolId: 9, effect: 'write' });
    expect(aggregate.steps[0].kindConfig).not.toHaveProperty('mcpServerId');
  });

  it("the effect select never offers less than the tool's base effect", async () => {
    answerTargets();
    renderAuthedPage(<BuilderPage />, { props: actionProps() });

    await userEvent.click(screen.getByRole('button', { name: 'Add an action' }));
    await chooseTool('Create issue');
    await userEvent.click(screen.getByRole('combobox', { name: 'Effect' }));

    const options = (await screen.findAllByRole('option')).map((option) => option.textContent);
    expect(options).toEqual(['Write', 'Send', 'Irreversible']);
  });

  it('an irreversible action without an approval shows the warning and can add one', async () => {
    const { bodies } = answerTargets();
    renderAuthedPage(<BuilderPage />, { props: actionProps() });

    await userEvent.click(screen.getByRole('button', { name: 'Add an action' }));
    await chooseTool('Create issue');
    expect(
      screen.queryByText('Add an approval step before this action; it will be refused on save otherwise.'),
    ).not.toBeInTheDocument();
    await chooseEffect('Irreversible');
    expect(
      screen.getByText('Add an approval step before this action; it will be refused on save otherwise.'),
    ).toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Add an approval before it' }));

    expect(
      screen.queryByText('Add an approval step before this action; it will be refused on save otherwise.'),
    ).not.toBeInTheDocument();
    const aggregate = await save(bodies);
    const [approval, action] = aggregate.steps;
    expect(approval).toMatchObject({
      kind: 'approval',
      kindConfig: { onTimeout: 'fail' },
      onFailure: 'fail',
      dependsOnStepIds: [],
    });
    expect(action).toMatchObject({ kind: 'action', dependsOnStepIds: [approval.key] });
  });

  it('an approval that skips when no one decides does not satisfy the warning', async () => {
    answerTargets();
    renderAuthedPage(<BuilderPage />, {
      props: actionProps({
        steps: [
          makeStep({
            id: 1,
            name: 'Sign off',
            position: 1,
            kind: 'approval',
            kindConfig: { timeoutSeconds: 3600, onTimeout: 'skip' },
          }),
          makeStep({
            id: 2,
            name: 'Notify',
            position: 2,
            kind: 'action',
            dependsOnStepIds: [1],
            kindConfig: {
              target: 'mcp_tool',
              mcpServerId: 5,
              tool: 'create_issue',
              arguments: {},
              effect: 'send',
              outputName: 'result.json',
            },
          }),
        ],
      }),
    });

    await userEvent.click(screen.getByText('Notify'));

    expect(
      await screen.findByText('Add an approval step before this action; it will be refused on save otherwise.'),
    ).toBeInTheDocument();
  });

  it("can't choose a drifted tool", async () => {
    const { bodies } = answerTargets();
    renderAuthedPage(<BuilderPage />, { props: actionProps() });

    await userEvent.click(screen.getByRole('button', { name: 'Add an action' }));
    await userEvent.click(await screen.findByRole('combobox', { name: 'Tool' }));

    const option = await screen.findByRole('option', { name: /Old tool/ });
    expect(option).toHaveAttribute('aria-disabled', 'true');
    expect(within(option).getByText('Changed since approved — review it on the server page')).toBeInTheDocument();
    await userEvent.click(option);

    expect(screen.getByRole('combobox', { name: 'Tool' })).toHaveValue('');
    const aggregate = await save(bodies);
    expect(aggregate.steps[0].kindConfig).not.toHaveProperty('tool');
  });

  it('reloads a saved action with its tool and arguments', async () => {
    answerTargets();
    renderAuthedPage(<BuilderPage />, {
      props: actionProps({
        steps: [
          makeStep({
            id: 1,
            name: 'File it',
            position: 1,
            kind: 'action',
            kindConfig: {
              target: 'mcp_tool',
              mcpServerId: 5,
              tool: 'create_issue',
              arguments: { title: 'Bug' },
              effect: 'write',
              outputName: 'result.json',
            },
          }),
        ],
      }),
    });

    expect(await screen.findByRole('combobox', { name: 'Tool' })).toHaveValue('Create issue');
    expect(screen.getByRole('textbox', { name: 'title' })).toHaveValue('Bug');
  });

  const savedAction = (kindConfig: Record<string, unknown>) =>
    actionProps({
      steps: [
        makeStep({
          id: 1,
          name: 'File it',
          position: 1,
          kind: 'action',
          kindConfig: { target: 'mcp_tool', mcpServerId: 5, arguments: {}, outputName: 'result.json', ...kindConfig },
        }),
      ],
    });

  it('warns on a saved action whose tool changed since it was approved', async () => {
    answerTargets();
    renderAuthedPage(<BuilderPage />, { props: savedAction({ tool: 'old_tool', effect: 'write' }) });

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent(
      'This tool changed since it was approved. Review the change on the server page before running this action.',
    );
    expect(within(alert).getByRole('link', { name: 'server page' })).toHaveAttribute(
      'href',
      '/company/projects/7/mcp_servers/5',
    );
  });

  it("shows a saved effect below the tool's own and asks to raise it", async () => {
    answerTargets();
    renderAuthedPage(<BuilderPage />, { props: savedAction({ tool: 'create_issue', effect: 'read' }) });

    expect(await screen.findByRole('combobox', { name: 'Effect' })).toHaveValue('Read');
    expect(screen.getByText("Below the tool's own effect (write). Raise it to write or higher.")).toBeInTheDocument();
  });

  it('says so when the action targets cannot be loaded', async () => {
    answerFetch({ [TARGETS_ROUTE]: new Response('{}', { status: 500 }), [CHECK_ROUTE]: { issues: [] } });
    renderAuthedPage(<BuilderPage />, { props: actionProps() });

    await userEvent.click(screen.getByRole('button', { name: 'Add an action' }));

    expect(await screen.findByText('The tools could not be loaded. Reload the page to try again.')).toBeInTheDocument();
  });

  describe('REST operations', () => {
    const REST_TARGETS = [
      ...TARGETS,
      target({
        type: 'rest_operation',
        mcpServerId: null,
        serverName: 'Billing API',
        tool: null,
        apiOperationId: 21,
        name: 'create_invoice',
        httpMethod: 'POST',
        path: '/invoices',
        description: 'Creates an invoice',
        inputSchema: { type: 'object', properties: { body: { type: 'object' } } },
      }),
    ];

    const answerRestTargets = () => {
      const bodies: SaveBody[] = [];
      answerFetch({
        [TARGETS_ROUTE]: REST_TARGETS,
        [SAVE_ROUTE]: (init?: RequestInit) => {
          const body = JSON.parse(String(init?.body)) as SaveBody;
          bodies.push(body);
          return savedState(body, makeWorkflow());
        },
        [CHECK_ROUTE]: { issues: [] },
      });
      return { bodies };
    };

    it('the builder lists REST operations under their connector', async () => {
      const { bodies } = answerRestTargets();
      renderAuthedPage(<BuilderPage />, { props: actionProps() });

      await userEvent.click(screen.getByRole('button', { name: 'Add an action' }));
      await userEvent.click(await screen.findByRole('combobox', { name: 'Tool' }));
      const group = await screen.findByRole('group', { name: 'Billing API' });
      const option = within(group).getByRole('option', { name: /\/invoices/ });
      expect(within(option).getByText('POST')).toBeInTheDocument();
      expect(within(option).getByText('/invoices')).toBeInTheDocument();
      await userEvent.click(option);

      expect(screen.getByText('Creates an invoice')).toBeInTheDocument();
      const aggregate = await save(bodies);
      expect(aggregate.steps[0]).toMatchObject({
        kind: 'action',
        kindConfig: { target: 'rest_operation', apiOperationId: 21, effect: 'write' },
      });
      expect(aggregate.steps[0].kindConfig).not.toHaveProperty('mcpServerId');
    });

    it('marks a saved operation that is gone and says operation, not tool', async () => {
      answerRestTargets();
      renderAuthedPage(<BuilderPage />, {
        props: actionProps({
          steps: [
            makeStep({
              id: 1,
              name: 'Bill',
              position: 1,
              kind: 'action',
              kindConfig: { target: 'rest_operation', apiOperationId: 99, arguments: {}, effect: 'write' },
            }),
          ],
        }),
      });

      expect(await screen.findByText('This operation is no longer available.')).toBeInTheDocument();
      expect(screen.queryByText('This tool is no longer available. Choose another one.')).not.toBeInTheDocument();
    });

    it('reloads a saved operation as the chosen target', async () => {
      answerRestTargets();
      renderAuthedPage(<BuilderPage />, {
        props: actionProps({
          steps: [
            makeStep({
              id: 1,
              name: 'Bill',
              position: 1,
              kind: 'action',
              kindConfig: { target: 'rest_operation', apiOperationId: 21, arguments: {}, effect: 'write' },
            }),
          ],
        }),
      });

      expect(await screen.findByRole('combobox', { name: 'Tool' })).toHaveValue('POST /invoices');
    });
  });

  it('Add an action is hidden while the flag is off', () => {
    renderAuthedPage(<BuilderPage />, { props: projectProps({ steps: [] }) });

    expect(screen.getByRole('button', { name: 'Add an approval' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Add an action' })).not.toBeInTheDocument();
  });
});

describe('Projects/Workflows/BuilderPage block steps', () => {
  const TARGETS_ROUTE = 'GET /api/v1/projects/7/action_targets';
  const BLOCKS_ROUTE = 'GET /api/v1/projects/7/blocks';

  const issueTarget = {
    type: 'mcp_tool',
    mcpServerId: 5,
    serverName: 'Linear',
    tool: 'create_issue',
    toolId: null,
    name: 'Create issue',
    description: null,
    inputSchema: { type: 'object', properties: { title: { type: 'string' } } },
    baseEffect: 'write',
    drifted: false,
  };

  const block = (overrides: Record<string, unknown> = {}) => ({
    key: 'acme/linear@1',
    label: 'File a bug',
    description: 'Opens a bug in Linear',
    executor: 'action',
    status: 'valid',
    reason: null,
    unresolved: false,
    effect: 'write',
    ports: { in: { team: 'string' }, out: { issue: 'object' } },
    config: {
      type: 'object',
      required: ['title'],
      properties: {
        title: { type: 'string', description: '<b>Short title</b>' },
        priority: { type: 'integer' },
      },
    },
    target: {
      type: 'mcp_tool',
      connection: 'Linear',
      operation: 'create_issue',
      name: 'Create issue',
      mcpServerId: 5,
      tool: 'create_issue',
      toolId: null,
      apiOperationId: null,
    },
    ...overrides,
  });

  const blockProps = (overrides: Record<string, unknown> = {}) =>
    projectProps({ steps: [], features: { workflowActionSteps: true }, ...overrides });

  function answerBlocks(blocks: unknown[]) {
    const bodies: SaveBody[] = [];
    answerFetch({
      [TARGETS_ROUTE]: [issueTarget],
      [BLOCKS_ROUTE]: blocks,
      [SAVE_ROUTE]: (init?: RequestInit) => {
        const body = JSON.parse(String(init?.body)) as SaveBody;
        bodies.push(body);
        return savedState(body, makeWorkflow());
      },
      [CHECK_ROUTE]: { issues: [] },
    });
    return { bodies };
  }

  it('does not load blocks until the picker is opened', async () => {
    answerBlocks([block()]);
    renderAuthedPage(<BuilderPage />, { props: blockProps() });

    expect(await screen.findByRole('button', { name: 'Add from a block' })).toBeInTheDocument();
    expect(fetch).not.toHaveBeenCalledWith(expect.stringContaining('/blocks'), expect.anything());
  });

  it('hides the block picker while the flag is off', () => {
    renderAuthedPage(<BuilderPage />, { props: projectProps({ steps: [] }) });

    expect(screen.queryByRole('button', { name: 'Add from a block' })).not.toBeInTheDocument();
  });

  it('lists only usable action blocks', async () => {
    answerBlocks([
      block(),
      block({ key: 'acme/broken@1', label: 'Broken', status: 'invalid', target: null }),
      block({ key: 'acme/ask@1', label: 'Ask someone', executor: 'agent', target: null }),
    ]);
    renderAuthedPage(<BuilderPage />, { props: blockProps() });

    await userEvent.click(screen.getByRole('button', { name: 'Add from a block' }));

    expect(await screen.findByRole('button', { name: /File a bug/ })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Broken/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Ask someone/ })).not.toBeInTheDocument();
  });

  it('picking a block saves an action with its target, provenance, output name and arguments', async () => {
    const { bodies } = answerBlocks([block()]);
    renderAuthedPage(<BuilderPage />, { props: blockProps() });

    await userEvent.click(screen.getByRole('button', { name: 'Add from a block' }));
    await userEvent.click(await screen.findByRole('button', { name: /File a bug/ }));

    expect(screen.getByText('<b>Short title</b>')).toBeInTheDocument();
    await userEvent.type(await screen.findByRole('textbox', { name: /title/ }), 'Crash on {{{{context:page}}');
    await userEvent.type(screen.getByRole('textbox', { name: 'priority' }), '2');

    const aggregate = await save(bodies);
    expect(aggregate.steps[0]).toMatchObject({
      name: 'File a bug',
      kind: 'action',
      kindConfig: {
        target: 'mcp_tool',
        mcpServerId: 5,
        tool: 'create_issue',
        block: 'acme/linear@1',
        effect: 'write',
        outputName: 'issue.json',
        arguments: { title: 'Crash on {{context:page}}', priority: 2 },
      },
      outputAssetSpecs: [{ name: 'issue.json' }],
    });
  });

  it('a block without out ports keeps the default output name', async () => {
    const { bodies } = answerBlocks([block({ ports: {} })]);
    renderAuthedPage(<BuilderPage />, { props: blockProps() });

    await userEvent.click(screen.getByRole('button', { name: 'Add from a block' }));
    await userEvent.click(await screen.findByRole('button', { name: /File a bug/ }));

    const aggregate = await save(bodies);
    expect(aggregate.steps[0].kindConfig).toMatchObject({ block: 'acme/linear@1', outputName: 'result.json' });
  });

  it('shows the block name and its port types on its step', async () => {
    answerBlocks([block()]);
    renderAuthedPage(<BuilderPage />, {
      props: blockProps({
        steps: [
          makeStep({
            id: 1,
            name: 'Bug',
            position: 1,
            kind: 'action',
            kindConfig: {
              target: 'mcp_tool',
              mcpServerId: 5,
              tool: 'create_issue',
              block: 'acme/linear@1',
              arguments: {},
            },
          }),
        ],
      }),
    });

    expect(await screen.findByText(/acme\/linear@1/)).toBeInTheDocument();
    expect(screen.getByText('team: string')).toBeInTheDocument();
    expect(screen.getByText('issue: object')).toBeInTheDocument();
  });

  const blockStep = (kindConfig: Record<string, unknown> = {}) =>
    makeStep({
      id: 1,
      name: 'Bug',
      position: 1,
      kind: 'action',
      kindConfig: {
        target: 'mcp_tool',
        mcpServerId: 5,
        tool: 'create_issue',
        block: 'acme/linear@1',
        arguments: {},
        effect: 'send',
        outputName: 'issue.json',
        ...kindConfig,
      },
    });

  it('does not offer the ordinary argument fields while the block is unavailable', async () => {
    answerFetch({
      [TARGETS_ROUTE]: [issueTarget],
      [BLOCKS_ROUTE]: new Response('{}', { status: 500 }),
    });
    renderAuthedPage(<BuilderPage />, { props: blockProps({ steps: [blockStep()] }) });

    expect(await screen.findByText('The block could not be loaded.')).toBeInTheDocument();
    expect(screen.queryByRole('textbox', { name: 'title' })).not.toBeInTheDocument();
  });

  it('holds the effect to the block and the output name to its port', async () => {
    answerBlocks([block({ effect: 'send' })]);
    renderAuthedPage(<BuilderPage />, { props: blockProps({ steps: [blockStep()] }) });

    expect(await screen.findByRole('textbox', { name: /title/ })).toBeInTheDocument();
    expect(screen.getByRole('textbox', { name: 'Output file' })).toBeDisabled();
    await userEvent.click(screen.getByRole('combobox', { name: 'Effect' }));
    expect(await screen.findByRole('option', { name: 'Send' })).toBeInTheDocument();
    expect(screen.queryByRole('option', { name: 'Write' })).not.toBeInTheDocument();
  });

  it('the block picker reports whether it is open', async () => {
    answerBlocks([block()]);
    renderAuthedPage(<BuilderPage />, { props: blockProps() });

    const toggle = screen.getByRole('button', { name: 'Add from a block' });
    expect(toggle).toHaveAttribute('aria-expanded', 'false');
    await userEvent.click(toggle);
    expect(toggle).toHaveAttribute('aria-expanded', 'true');
  });
});
