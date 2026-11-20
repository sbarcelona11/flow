import '@testing-library/jest-dom/vitest';
import { useState } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { ModuleBlock, Step } from '@/types/generated';
import { buildCompositeBlock } from 'test/factories/moduleBlock';
import { reportResizes } from 'test/reactFlowEnvironment';
import { act, fireEvent, renderPage, screen, userEvent, waitFor, within } from 'test/renderPage';

import { draftBlockStep, draftStep, withDependency } from '../builderDraft';
import type { IssueFix, WorkflowIssue } from '../dataFlow';

import { autoLayout } from './layout';
import WorkflowCanvas from './WorkflowCanvas';

const step = (id: number, name: string, patch: Partial<Step> = {}): Step => ({
  ...draftStep([], name),
  id,
  position: id,
  ...patch,
});

const block = (key: string, ports: ModuleBlock['ports']): ModuleBlock => ({
  key,
  label: key,
  executor: 'action',
  config: {},
  origin: 'web',
  reviewState: 'reviewed',
  status: 'valid',
  reason: null,
  unresolved: false,
  effect: 'read',
  description: null,
  composite: null,
  ports,
  target: {
    type: 'wrapper',
    connection: null,
    operation: 'x',
    name: 'x',
    mcpServerId: null,
    tool: null,
    toolId: 1,
    apiOperationId: null,
  },
});
const fetchBlock = block('fetch', { in: {}, out: { rows: 'list<row>' } });
const sendBlock = block('send', { in: { row: 'row' }, out: {} });

const steps = [
  step(1, 'Draft spec'),
  step(2, 'Approve spec', {
    kind: 'approval',
    kindConfig: { timeoutSeconds: 7200, onTimeout: 'skip' },
    dependsOnStepIds: [1],
  }),
  step(3, 'Cool off', { kind: 'wait', kindConfig: { delaySeconds: 3600 }, dependsOnStepIds: [2] }),
];

function showCanvas(overrides: { issues?: WorkflowIssue[]; onSelect?: (id: number | null) => void } = {}) {
  const onSelect = overrides.onSelect ?? vi.fn();
  renderPage(
    <div style={{ width: 1200, height: 600 }}>
      <WorkflowCanvas
        steps={steps}
        issues={overrides.issues ?? []}
        blocks={[]}
        selection={null}
        readOnly
        onSelect={onSelect}
      />
    </div>,
  );
  return onSelect;
}

describe('Projects/Workflows/canvas/WorkflowCanvas', () => {
  it('names each node by kind, name, what it runs after and its problems', () => {
    showCanvas();

    expect(screen.getByRole('region', { name: 'Workflow canvas' })).toBeInTheDocument();
    expect(screen.getByRole('group', { name: 'Session Draft spec, 0 problems' })).toBeInTheDocument();
    expect(
      screen.getByRole('group', { name: 'Approval Approve spec, runs after Draft spec, 0 problems' }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole('group', { name: 'Wait Cool off, runs after Approve spec, 0 problems' }),
    ).toBeInTheDocument();
  });

  it('summarises approval and wait steps and shows the first problem as text', () => {
    showCanvas({
      issues: [
        {
          severity: 'error',
          code: 'missing_input',
          stepKey: '2',
          field: 'instructions',
          message: 'No output named plan.',
        },
      ],
    });

    const approval = screen.getByRole('group', { name: 'Approval Approve spec, runs after Draft spec, 1 problem' });
    expect(approval).toHaveTextContent('Times out after 2 h, then skips');
    expect(approval).toHaveTextContent('No output named plan.');
    expect(screen.getByRole('group', { name: 'Wait Cool off, runs after Approve spec, 0 problems' })).toHaveTextContent(
      'Waits 1 h',
    );
  });

  it('shows a cap chip as plain text on a capped agent step and on none else', () => {
    renderPage(
      <div style={{ width: 1200, height: 600 }}>
        <WorkflowCanvas
          steps={[
            step(1, 'Draft spec', { budgetCents: 150 }),
            step(2, 'Approve spec', { kind: 'approval', budgetCents: 100, dependsOnStepIds: [1] }),
            step(3, 'Plain'),
          ]}
          issues={[]}
          blocks={[]}
          selection={null}
          readOnly
          onSelect={vi.fn()}
        />
      </div>,
    );

    const chip = screen.getByRole('group', { name: 'Budget cap $1.50' });
    expect(chip).toHaveTextContent('Cap $1.50');
    expect(screen.getAllByText(/^Cap \$/)).toHaveLength(1);
  });

  it('selects the focused node on Enter', async () => {
    const onSelect = showCanvas();

    screen.getByRole('group', { name: 'Wait Cool off, runs after Approve spec, 0 problems' }).focus();
    await userEvent.keyboard('{Enter}');

    expect(onSelect).toHaveBeenCalledWith(3);
  });

  it('selects a node on click', async () => {
    const onSelect = showCanvas();

    // userEvent's mousedown has no `view`, which React Flow's d3-zoom pan handler needs in jsdom.
    fireEvent.click(screen.getByRole('group', { name: 'Session Draft spec, 0 problems' }));

    expect(onSelect).toHaveBeenCalledWith(1);
  });

  it('offers no way to delete a step while read-only', async () => {
    const onSelect = showCanvas();

    screen.getByRole('group', { name: 'Session Draft spec, 0 problems' }).focus();
    await userEvent.keyboard('{Delete}');

    expect(screen.queryByRole('button', { name: /delete|remove/i })).not.toBeInTheDocument();
    expect(screen.getByRole('group', { name: 'Session Draft spec, 0 problems' })).toBeInTheDocument();
    expect(onSelect).not.toHaveBeenCalled();
  });
});

const nodeName = (kind: string, name: string, after = '', problems = 0) =>
  `${kind} ${name}${after ? `, runs after ${after}` : ''}, ${problems} ${problems === 1 ? 'problem' : 'problems'}`;

interface HostProps {
  initial: Step[];
  readOnly?: boolean;
  blocks?: ModuleBlock[];
  issues?: WorkflowIssue[];
  selected?: number | null;
  onStepsChange?: (updater: (steps: Step[]) => Step[]) => void;
  onRequestDelete?: (id: number) => void;
  announce?: (message: string) => void;
  actionsEnabled?: boolean;
  blocksStatus?: 'idle' | 'loading' | 'ready' | 'error';
  onWantBlocks?: () => void;
  fixLabel?: (fix: IssueFix) => string | null;
  onInsertComposite?: (block: ModuleBlock, at: { x: number; y: number }, after?: number | null) => void;
}

/** The builder's side of the contract: the draft and the selection live here, the canvas edits them. */
function Host({ initial, readOnly = false, blocks = [], issues = [], selected = null, ...spies }: HostProps) {
  const [draft, setDraft] = useState(initial);
  const [selectedId, setSelectedId] = useState<number | null>(selected);
  const sorted = [...draft].sort((a, b) => a.position - b.position);
  return (
    <>
      <div style={{ width: 1200, height: 600 }}>
        <WorkflowCanvas
          steps={sorted}
          issues={issues}
          blocks={blocks}
          blocksStatus={spies.blocksStatus}
          actionsEnabled={spies.actionsEnabled}
          onWantBlocks={spies.onWantBlocks}
          selection={selectedId == null ? null : { mode: 'session', sessionId: selectedId }}
          readOnly={readOnly}
          onSelect={setSelectedId}
          onStepsChange={(updater) => {
            spies.onStepsChange?.(updater);
            setDraft(updater);
          }}
          onRequestDelete={spies.onRequestDelete}
          announce={spies.announce}
          fixLabel={spies.fixLabel}
          onInsertComposite={spies.onInsertComposite}
          onFix={(stepId, fix) => {
            if (fix.kind !== 'add_dependency') return;
            const dependency = draft.find((s) => String(s.id) === fix.stepKey);
            if (dependency) setDraft((prev) => withDependency(prev, stepId, dependency.id) ?? prev);
          }}
        />
      </div>
      <button type="button" onClick={() => setSelectedId(1)}>
        Select Draft spec
      </button>
      <button type="button">Elsewhere</button>
      <p>{`Selected: ${draft.find((s) => s.id === selectedId)?.name ?? 'none'}`}</p>
      <ul aria-label="Draft positions">
        {draft.map((s) => (
          <li
            key={s.id}
          >{`${s.name}: ${s.canvasPosition ? `${s.canvasPosition.x},${s.canvasPosition.y}` : 'auto'}`}</li>
        ))}
      </ul>
    </>
  );
}

const draftPosition = (name: string) =>
  within(screen.getByRole('list', { name: 'Draft positions' }))
    .getByText(new RegExp(`^${name}: `))
    .textContent?.split(': ')[1];

const editable = [...steps, step(4, 'Extra')];

describe('Projects/Workflows/canvas/WorkflowCanvas editing', () => {
  let restoreResizeObserver: () => void;
  beforeEach(() => {
    restoreResizeObserver = reportResizes();
  });
  afterEach(() => restoreResizeObserver());

  it('moves a selected node with the arrow keys and writes the draft once, on key-up', async () => {
    const onStepsChange = vi.fn();
    const announce = vi.fn();
    renderPage(<Host initial={editable} onStepsChange={onStepsChange} announce={announce} />);

    // One instance, so the held key is still down when the next call releases it.
    const user = userEvent.setup();
    screen.getByRole('group', { name: nodeName('Session', 'Extra') }).focus();
    await user.keyboard('{Enter}');
    await user.keyboard('{ArrowRight>}');
    expect(onStepsChange).not.toHaveBeenCalled();
    await user.keyboard('{/ArrowRight}');

    const auto = autoLayout(editable).get(4);
    expect(onStepsChange).toHaveBeenCalledTimes(1);
    expect(draftPosition('Extra')).toBe(`${(auto?.x ?? 0) + 5},${auto?.y}`);
    // The first move stores every position, so the others stay where they were drawn.
    expect(draftPosition('Draft spec')).toBe(`${autoLayout(editable).get(1)?.x},${autoLayout(editable).get(1)?.y}`);
    expect(announce).toHaveBeenCalledWith('Extra moved');
  });

  it('connects through the Run after menu, offering no step that would close a loop', async () => {
    const announce = vi.fn();
    renderPage(<Host initial={editable} selected={1} announce={announce} />);

    await userEvent.click(screen.getByRole('button', { name: 'Run Draft spec after…' }));
    const menu = await screen.findByRole('menu');

    // Approve spec and Cool off already run after Draft spec, directly or not.
    expect(
      within(menu)
        .getAllByRole('menuitem')
        .map((item) => item.textContent),
    ).toEqual(['Extra']);
    await userEvent.click(within(menu).getByRole('menuitem', { name: 'Extra' }));

    expect(await screen.findByRole('group', { name: nodeName('Session', 'Draft spec', 'Extra') })).toBeInTheDocument();
    expect(await screen.findByLabelText('Draft spec runs after Extra')).toBeInTheDocument();
    expect(announce).toHaveBeenCalledWith('Draft spec now runs after Extra');
  });

  it('asks the builder to delete a selected node and leaves the draft alone', async () => {
    const onRequestDelete = vi.fn();
    renderPage(<Host initial={editable} onRequestDelete={onRequestDelete} />);

    screen.getByRole('group', { name: nodeName('Wait', 'Cool off', 'Approve spec') }).focus();
    await userEvent.keyboard('{Enter}{Delete}');

    expect(onRequestDelete).toHaveBeenCalledWith(3);
    expect(screen.getByRole('group', { name: nodeName('Wait', 'Cool off', 'Approve spec') })).toBeInTheDocument();
  });

  it('removes a dependency from its edge button', async () => {
    const announce = vi.fn();
    renderPage(<Host initial={editable} announce={announce} />);

    fireEvent.click(await screen.findByLabelText('Approve spec runs after Draft spec'));
    await userEvent.click(await screen.findByRole('button', { name: /Remove dependency/ }));

    expect(await screen.findByRole('group', { name: nodeName('Approval', 'Approve spec') })).toBeInTheDocument();
    expect(screen.queryByLabelText('Approve spec runs after Draft spec')).not.toBeInTheDocument();
    expect(announce).toHaveBeenCalledWith('Approve spec no longer runs after Draft spec');
  });

  it('removes the selected dependency with Delete', async () => {
    renderPage(<Host initial={editable} />);

    const edge = await screen.findByLabelText('Approve spec runs after Draft spec');
    fireEvent.click(edge);
    edge.focus();
    await userEvent.keyboard('{Delete}');

    expect(await screen.findByRole('group', { name: nodeName('Approval', 'Approve spec') })).toBeInTheDocument();
  });

  it('tidies up: every step gets its auto-layout position', async () => {
    const scattered = editable.map((s, i) => ({ ...s, canvasPosition: { x: 900 - i * 7, y: 400 + i * 3 } }));
    renderPage(<Host initial={scattered} />);

    await userEvent.click(screen.getByRole('button', { name: 'Tidy up' }));

    const auto = autoLayout(editable);
    for (const s of editable) expect(draftPosition(s.name)).toBe(`${auto.get(s.id)?.x},${auto.get(s.id)?.y}`);
  });

  it('exposes no editing controls while read-only, whatever the host passes', async () => {
    const onStepsChange = vi.fn();
    const onRequestDelete = vi.fn();
    renderPage(
      <Host initial={editable} readOnly selected={1} onStepsChange={onStepsChange} onRequestDelete={onRequestDelete} />,
    );

    expect(screen.queryByRole('button', { name: 'Tidy up' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Run .* after…/ })).not.toBeInTheDocument();
    screen.getByRole('group', { name: nodeName('Session', 'Draft spec') }).focus();
    await userEvent.keyboard('{Enter}{ArrowRight}{Delete}');
    fireEvent.click(await screen.findByLabelText('Approve spec runs after Draft spec'));

    expect(screen.queryByRole('button', { name: /Remove dependency/ })).not.toBeInTheDocument();
    expect(onStepsChange).not.toHaveBeenCalled();
    expect(onRequestDelete).not.toHaveBeenCalled();
  });

  it('highlights the selected node and follows a selection made elsewhere', async () => {
    renderPage(<Host initial={editable} selected={2} />);
    expect(screen.getByRole('group', { name: nodeName('Approval', 'Approve spec', 'Draft spec') })).toHaveClass(
      'selected',
    );
    expect(screen.getByRole('group', { name: nodeName('Session', 'Draft spec') })).not.toHaveClass('selected');

    await userEvent.click(screen.getByRole('button', { name: 'Select Draft spec' }));

    expect(screen.getByRole('group', { name: nodeName('Session', 'Draft spec') })).toHaveClass('selected');
    expect(screen.getByRole('group', { name: nodeName('Approval', 'Approve spec', 'Draft spec') })).not.toHaveClass(
      'selected',
    );
  });

  it('acts on the delete key only while focus is inside the canvas', async () => {
    const onStepsChange = vi.fn();
    const onRequestDelete = vi.fn();
    renderPage(
      <Host initial={editable} selected={2} onStepsChange={onStepsChange} onRequestDelete={onRequestDelete} />,
    );
    fireEvent.click(await screen.findByLabelText('Approve spec runs after Draft spec'));

    screen.getByRole('button', { name: 'Elsewhere' }).focus();
    await userEvent.keyboard('{Delete}{Backspace}');

    expect(onStepsChange).not.toHaveBeenCalled();
    expect(onRequestDelete).not.toHaveBeenCalled();
  });

  it('deletes the focused node, not just any selected one, with Backspace', async () => {
    const onRequestDelete = vi.fn();
    renderPage(<Host initial={editable} selected={1} onRequestDelete={onRequestDelete} />);

    screen.getByRole('group', { name: nodeName('Wait', 'Cool off', 'Approve spec') }).focus();
    await userEvent.keyboard('{Enter}{Backspace}');

    expect(onRequestDelete).toHaveBeenCalledWith(3);
  });

  it('does not reselect a removed dependency when it is added again', async () => {
    renderPage(<Host initial={editable} selected={2} />);
    fireEvent.click(await screen.findByLabelText('Approve spec runs after Draft spec'));
    await userEvent.click(await screen.findByRole('button', { name: /Remove dependency/ }));
    await screen.findByRole('group', { name: nodeName('Approval', 'Approve spec') });

    await userEvent.click(screen.getByRole('button', { name: 'Run Approve spec after…' }));
    await userEvent.click(await screen.findByRole('menuitem', { name: 'Draft spec' }));

    expect(await screen.findByLabelText('Approve spec runs after Draft spec')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Remove dependency/ })).not.toBeInTheDocument();
  });

  it('keeps keyboard focus in the canvas after a dependency is removed', async () => {
    renderPage(<Host initial={editable} />);
    fireEvent.click(await screen.findByLabelText('Approve spec runs after Draft spec'));
    await userEvent.click(await screen.findByRole('button', { name: /Remove dependency/ }));

    await screen.findByRole('group', { name: nodeName('Approval', 'Approve spec') });
    expect(screen.getByRole('region', { name: 'Workflow canvas' })).toHaveFocus();
  });

  it('says there is nothing to choose in an empty Run after menu', async () => {
    renderPage(<Host initial={steps} selected={1} />);

    await userEvent.click(screen.getByRole('button', { name: 'Run Draft spec after…' }));

    expect(await screen.findByRole('menuitem', { name: 'No other step can come first' })).toBeInTheDocument();
  });

  it('describes keys that exist: Delete only when editable, and no second move announcement', async () => {
    const { unmount } = renderPage(<Host initial={editable} selected={1} />);
    const node = screen.getByRole('group', { name: nodeName('Session', 'Draft spec') });
    expect(node).toHaveAccessibleDescription(/Delete/);
    node.focus();
    await userEvent.keyboard('{Enter}{ArrowRight}');
    expect(screen.queryByText(/Moved selected node/)).not.toBeInTheDocument();
    unmount();

    renderPage(<Host initial={editable} readOnly />);
    expect(screen.getByRole('group', { name: nodeName('Session', 'Draft spec') })).not.toHaveAccessibleDescription(
      /delete/i,
    );
  });
});

describe('Projects/Workflows/canvas/WorkflowCanvas large graphs and overview', () => {
  let restoreResizeObserver: () => void;
  beforeEach(() => {
    restoreResizeObserver = reportResizes();
  });
  afterEach(() => restoreResizeObserver());

  const many = (count: number) => Array.from({ length: count }, (_, i) => step(i + 1, `Step ${i + 1}`));

  it('shows the overview map above 30 nodes only', () => {
    const { unmount } = renderPage(<Host initial={many(30)} />);
    expect(screen.queryByLabelText('Workflow overview')).not.toBeInTheDocument();
    unmount();

    renderPage(<Host initial={many(31)} />);
    expect(screen.getByLabelText('Workflow overview')).toBeInTheDocument();
  });

  it('keeps every node in the Tab order once focus is inside a large canvas', async () => {
    renderPage(<Host initial={many(61)} />);
    const first = await screen.findByRole('group', { name: nodeName('Session', 'Step 1') });

    // Only the nodes in the viewport are in the DOM until focus enters the canvas.
    expect(screen.queryByRole('group', { name: nodeName('Session', 'Step 61') })).not.toBeInTheDocument();
    act(() => first.focus());

    expect(await screen.findByRole('group', { name: nodeName('Session', 'Step 61') })).toBeInTheDocument();
  });

  it('marks an edge whose output type does not match', async () => {
    const base = { ...draftBlockStep([], fetchBlock), position: 1, id: 1 };
    const target = draftBlockStep([], sendBlock);
    const consumer = {
      ...target,
      id: 2,
      position: 2,
      dependsOnStepIds: [1],
      kindConfig: { ...target.kindConfig, arguments: { row: '{{output:1:rows.json}}' } },
    };
    renderPage(
      <Host
        initial={[base, consumer]}
        blocks={[fetchBlock, sendBlock]}
        issues={[
          {
            severity: 'error',
            code: 'type_mismatch',
            stepKey: '2',
            field: 'arguments.row',
            message: 'list<row> is not row',
          },
        ]}
      />,
    );

    expect(await screen.findByLabelText(/feeds .*, output type does not match/)).toBeInTheDocument();
  });
});

describe('Projects/Workflows/canvas/WorkflowCanvas connecting by drag', () => {
  let restoreResizeObserver: () => void;
  beforeEach(() => {
    restoreResizeObserver = reportResizes();
  });
  afterEach(() => {
    restoreResizeObserver();
    vi.restoreAllMocks();
  });

  // jsdom has no hit testing: the drop target is whatever the test says is under the pointer.
  async function drag(from: string, to: string) {
    const target = await screen.findByTestId(to);
    Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => target });
    Object.defineProperty(document, 'elementsFromPoint', { configurable: true, value: () => [target] });
    fireEvent.mouseDown(await screen.findByTestId(from), { button: 0, clientX: 1, clientY: 1 });
    fireEvent.mouseMove(document, { clientX: 50, clientY: 50 });
    fireEvent.mouseUp(document, { clientX: 50, clientY: 50 });
  }

  it('connects out to in as "runs after"', async () => {
    const onStepsChange = vi.fn();
    renderPage(<Host initial={editable} onStepsChange={onStepsChange} />);

    await drag('handle:4:out', 'handle:1:in');

    expect(await screen.findByRole('group', { name: nodeName('Session', 'Draft spec', 'Extra') })).toBeInTheDocument();
  });

  it('connects from an in handle to an out handle the same way round', async () => {
    renderPage(<Host initial={editable} />);

    await drag('handle:1:in', 'handle:4:out');

    expect(await screen.findByRole('group', { name: nodeName('Session', 'Draft spec', 'Extra') })).toBeInTheDocument();
  });

  it('only explains a refused drop that started on an in handle, and edits nothing', async () => {
    const onStepsChange = vi.fn();
    const announce = vi.fn();
    renderPage(<Host initial={editable} onStepsChange={onStepsChange} announce={announce} />);

    // Cool off runs after Draft spec; "Draft spec runs after Cool off" would loop.
    await drag('handle:1:in', 'handle:3:out');

    await waitFor(() => expect(announce).toHaveBeenCalledWith(expect.stringContaining('loop back on itself')));
    expect(onStepsChange).not.toHaveBeenCalled();
  });

  it('names an existing dependency as such, not as a loop', async () => {
    const onStepsChange = vi.fn();
    const announce = vi.fn();
    renderPage(<Host initial={editable} onStepsChange={onStepsChange} announce={announce} />);

    await drag('handle:2:in', 'handle:1:out');

    await waitFor(() => expect(announce).toHaveBeenCalledWith('Approve spec already runs after Draft spec'));
    expect(onStepsChange).not.toHaveBeenCalled();
  });

  it.each([
    ['handle:1:out', 'handle:4:out'],
    ['handle:1:in', 'handle:4:in'],
  ])('does nothing but explain when %s is dropped on %s', async (from, to) => {
    const onStepsChange = vi.fn();
    const announce = vi.fn();
    renderPage(<Host initial={editable} onStepsChange={onStepsChange} announce={announce} />);

    await drag(from, to);

    await waitFor(() =>
      expect(announce).toHaveBeenCalledWith('Connect a step’s out handle to another step’s in handle'),
    );
    expect(onStepsChange).not.toHaveBeenCalled();
  });
});

describe('Projects/Workflows/canvas/WorkflowCanvas palette', () => {
  let restoreResizeObserver: () => void;
  beforeEach(() => {
    restoreResizeObserver = reportResizes();
  });
  afterEach(() => restoreResizeObserver());

  const palette = () => screen.getByRole('list', { name: 'Steps' });
  const flagged = { actionsEnabled: true, blocksStatus: 'ready' } as const;

  it('adds an approval to the right of the selected step, running after it, selected, focused and announced', async () => {
    const announce = vi.fn();
    renderPage(<Host initial={editable} selected={1} announce={announce} />);

    await userEvent.click(within(palette()).getByRole('button', { name: 'Approval' }));

    const added = await screen.findByRole('group', { name: nodeName('Approval', 'Approval 5', 'Draft spec') });
    expect(screen.getByText('Selected: Approval 5')).toBeInTheDocument();
    await waitFor(() => expect(added).toHaveFocus());
    expect(announce).toHaveBeenCalledWith('Approval 5 added, runs after Draft spec');
    const [x, y] = (draftPosition('Approval 5') ?? '').split(',').map(Number);
    expect(x).toBe((autoLayout(editable).get(1)?.x ?? 0) + 360);
    // Approve spec already sits in that column, so the new step moves down to a free row.
    expect(`${x},${y}`).not.toBe(draftPosition('Approve spec'));
  });

  it('keeps the steps that were laid out automatically where they were drawn', async () => {
    renderPage(<Host initial={editable} selected={1} />);

    await userEvent.click(within(palette()).getByRole('button', { name: 'Wait' }));

    await screen.findByRole('group', { name: nodeName('Wait', 'Wait 5', 'Draft spec') });
    const laid = autoLayout(editable);
    for (const [id, name] of [
      [1, 'Draft spec'],
      [2, 'Approve spec'],
      [3, 'Cool off'],
      [4, 'Extra'],
    ] as const)
      expect(draftPosition(name)).toBe(`${laid.get(id)?.x},${laid.get(id)?.y}`);
  });

  it('adds a step that runs after nothing when no step is selected', async () => {
    renderPage(<Host initial={editable} />);

    await userEvent.click(within(palette()).getByRole('button', { name: 'Session' }));

    expect(await screen.findByRole('group', { name: nodeName('Session', 'Session 5') })).toBeInTheDocument();
    expect(screen.getByText('Selected: Session 5')).toBeInTheDocument();
    expect(draftPosition('Session 5')).not.toBe('auto');
  });

  it('does not put the new step on top of another one', async () => {
    renderPage(<Host initial={editable} selected={1} />);

    await userEvent.click(within(palette()).getByRole('button', { name: 'Approval' }));
    await userEvent.click(within(palette()).getByRole('button', { name: 'Wait' }));
    await screen.findByRole('group', { name: nodeName('Wait', 'Wait 6', 'Approval 5') });

    const where = (name: string) => draftPosition(name);
    expect(where('Wait 6')).not.toBe(where('Approval 5'));
  });

  it('creates the block action step the list view creates, from a block entry', async () => {
    const onWantBlocks = vi.fn();
    const blocks = [{ ...fetchBlock, label: 'Fetch rows' }];
    renderPage(<Host initial={editable} selected={1} blocks={blocks} onWantBlocks={onWantBlocks} {...flagged} />);

    await userEvent.click(screen.getByRole('button', { name: /^Fetch rows/ }));

    expect(onWantBlocks).toHaveBeenCalled();
    const expected = draftBlockStep(editable, blocks[0]);
    expect(
      await screen.findByRole('group', { name: nodeName('Action', 'Fetch rows', 'Draft spec') }),
    ).toBeInTheDocument();
    expect(screen.getByText(`Selected: ${expected.name}`)).toBeInTheDocument();
  });

  it('offers Action only with the flag', () => {
    renderPage(<Host initial={editable} />);

    expect(within(palette()).queryByRole('button', { name: 'Action' })).not.toBeInTheDocument();
    expect(screen.queryByRole('list', { name: 'Blocks' })).not.toBeInTheDocument();
  });

  it('has no palette while read-only', () => {
    renderPage(<Host initial={editable} readOnly {...flagged} />);

    expect(screen.queryByRole('list', { name: 'Steps' })).not.toBeInTheDocument();
    expect(screen.queryByRole('textbox', { name: 'Search blocks' })).not.toBeInTheDocument();
  });

  it('keeps Delete on a palette button from removing the selected dependency', async () => {
    const onRequestDelete = vi.fn();
    renderPage(<Host initial={editable} selected={1} onRequestDelete={onRequestDelete} />);

    within(palette()).getByRole('button', { name: 'Wait' }).focus();
    await userEvent.keyboard('{Delete}');

    expect(onRequestDelete).not.toHaveBeenCalled();
  });

  it('adds an approval before a send action from its menu', async () => {
    const send = step(5, 'Send mail', {
      kind: 'action',
      kindConfig: { target: 'mcp_tool', tool: 'send', effect: 'send', arguments: {}, outputName: 'result' },
      dependsOnStepIds: [1],
    });
    const announce = vi.fn();
    renderPage(<Host initial={[steps[0], send]} selected={5} announce={announce} />);

    await userEvent.click(await screen.findByRole('button', { name: 'Run Send mail after…' }));
    await userEvent.click(await screen.findByRole('menuitem', { name: 'Add approval before' }));

    expect(
      await screen.findByRole('group', { name: nodeName('Approval', 'Approve Send mail', 'Draft spec') }),
    ).toBeInTheDocument();
    expect(
      await screen.findByRole('group', { name: /^Action Send mail, runs after .*Approve Send mail/ }),
    ).toBeInTheDocument();
    expect(screen.getByText('Selected: Approve Send mail')).toBeInTheDocument();
    expect(announce).toHaveBeenCalledWith('Approve Send mail added before Send mail');
    const laid = autoLayout([steps[0], send]);
    expect(draftPosition('Send mail')).toBe(`${laid.get(5)?.x},${laid.get(5)?.y}`);
  });

  it('offers no approval before a read-only or write action', async () => {
    const write = step(5, 'Write file', {
      kind: 'action',
      kindConfig: { target: 'mcp_tool', tool: 'w', effect: 'write', arguments: {}, outputName: 'result' },
    });
    renderPage(<Host initial={[write]} selected={5} />);

    await userEvent.click(await screen.findByRole('button', { name: 'Run Write file after…' }));

    expect(screen.queryByRole('menuitem', { name: 'Add approval before' })).not.toBeInTheDocument();
  });
});

describe('Projects/Workflows/canvas/WorkflowCanvas typed ports', () => {
  let restoreResizeObserver: () => void;
  beforeEach(() => {
    restoreResizeObserver = reportResizes();
  });
  afterEach(() => restoreResizeObserver());

  const mcp = (key: string, ports: ModuleBlock['ports']): ModuleBlock => {
    const base = block(key, ports);
    return { ...base, target: base.target && { ...base.target, type: 'mcp_tool' } };
  };
  const fetcher = mcp('fetch', { in: {}, out: { rows: 'list<row>', note: 'string' } });
  const sender = mcp('send', { in: { row: 'row', loose: '' }, out: {} });
  const action = (id: number, name: string, key: string, patch: Partial<Step['kindConfig']> = {}) =>
    step(id, name, {
      kind: 'action',
      kindConfig: { target: 'mcp_tool', block: key, arguments: {}, effect: 'read', ...patch },
    });
  const rowsFile = [{ name: 'rows.json', assetType: 'file' as const, required: true }];
  const pair = [{ ...action(1, 'Fetch rows', 'fetch'), outputAssetSpecs: rowsFile }, action(2, 'Send rows', 'send')];

  it('shows each port as text with its type, "any" when untyped', () => {
    renderPage(<Host initial={pair} blocks={[fetcher, sender]} />);

    const node = screen.getByRole('group', { name: /^Action Send rows/ });
    expect(within(node).getByRole('group', { name: 'Input row, type row' })).toHaveTextContent('in row: row');
    expect(within(node).getByRole('group', { name: 'Input loose, type any' })).toHaveTextContent('in loose: any');
    expect(
      within(screen.getByRole('group', { name: /^Action Fetch rows/ })).getByRole('group', {
        name: 'Output rows, type list<row>',
      }),
    ).toBeInTheDocument();
  });

  it('binds an argument through the Bind to menu: writes the token, adds the dependency, announces', async () => {
    const announce = vi.fn();
    const onStepsChange = vi.fn();
    renderPage(
      <Host initial={pair} blocks={[fetcher, sender]} selected={2} announce={announce} onStepsChange={onStepsChange} />,
    );

    await userEvent.click(screen.getByRole('button', { name: 'Bind row of Send rows to…' }));
    const menu = await screen.findByRole('menu');
    // No type filtering: a list<row> port is offered for a row argument.
    expect(
      within(menu)
        .getAllByRole('menuitem')
        .map((item) => item.textContent),
    ).toEqual(['Fetch rows: rows (list<row>)']);
    await userEvent.click(within(menu).getByRole('menuitem', { name: 'Fetch rows: rows (list<row>)' }));

    const next = onStepsChange.mock.calls[0][0](pair) as Step[];
    expect(next.find((s) => s.id === 2)?.kindConfig.arguments).toEqual({ row: '{{output:1:rows.json}}' });
    expect(next.find((s) => s.id === 2)?.dependsOnStepIds).toEqual([1]);
    expect(await screen.findByLabelText('Fetch rows feeds Send rows')).toBeInTheDocument();
    expect(announce).toHaveBeenCalledWith('Send rows now reads row from Fetch rows: rows');
  });

  it('offers no step that would loop back, and removes a binding without dropping the dependency', async () => {
    const bound = [
      pair[0],
      {
        ...pair[1],
        dependsOnStepIds: [1],
        kindConfig: { ...pair[1].kindConfig, arguments: { row: '{{output:1:rows.json}}' } },
      },
    ];
    const onStepsChange = vi.fn();
    renderPage(<Host initial={bound} blocks={[fetcher, sender]} selected={2} onStepsChange={onStepsChange} />);

    expect(screen.getByRole('group', { name: 'Input row, type row, bound' })).toHaveTextContent('in row: row (bound)');
    await userEvent.click(screen.getByRole('button', { name: 'Bind row of Send rows to…' }));
    await userEvent.click(await screen.findByRole('menuitem', { name: 'Remove binding' }));

    const next = onStepsChange.mock.calls[0][0](bound) as Step[];
    expect(next.find((s) => s.id === 2)?.kindConfig.arguments).toEqual({});
    expect(next.find((s) => s.id === 2)?.dependsOnStepIds).toEqual([1]);
  });

  it('offers no source when every earlier step would loop back', async () => {
    const onStepsChange = vi.fn();
    const looped = [{ ...pair[0], dependsOnStepIds: [2] }, pair[1]];
    renderPage(<Host initial={looped} blocks={[fetcher, sender]} selected={2} onStepsChange={onStepsChange} />);

    await userEvent.click(screen.getByRole('button', { name: 'Bind row of Send rows to…' }));

    expect(await screen.findByText('No earlier step has an output port')).toBeInTheDocument();
    expect(screen.queryByRole('menuitem')).not.toBeInTheDocument();
    expect(onStepsChange).not.toHaveBeenCalled();
  });

  it('refuses a twenty-first output token with a notification, once, and leaves the draft alone', async () => {
    const announce = vi.fn();
    const onStepsChange = vi.fn();
    const crowded = {
      ...pair[1],
      kindConfig: {
        ...pair[1].kindConfig,
        arguments: { many: Array.from({ length: 20 }, (_, i) => ({ v: `{{output:1:p${i}.json}}` })) },
      },
    };
    renderPage(
      <Host
        initial={[pair[0], crowded]}
        blocks={[fetcher, sender]}
        selected={2}
        announce={announce}
        onStepsChange={onStepsChange}
      />,
    );

    await userEvent.click(screen.getByRole('button', { name: 'Bind row of Send rows to…' }));
    await userEvent.click(await screen.findByRole('menuitem', { name: 'Fetch rows: rows (list<row>)' }));

    expect(
      await screen.findByText('Send rows already reads 20 step outputs, the most one action can'),
    ).toBeInTheDocument();
    expect(onStepsChange).not.toHaveBeenCalled();
    expect(announce).not.toHaveBeenCalled();
  });

  it('offers no binding on a Wrapper target, which cannot read step outputs', () => {
    const wrapper = action(2, 'Send rows', 'send', { target: 'wrapper' });
    renderPage(<Host initial={[pair[0], wrapper]} blocks={[fetcher, sender]} selected={2} />);

    expect(screen.queryByRole('button', { name: /^Bind / })).not.toBeInTheDocument();
  });

  it('offers no binding while read-only', () => {
    renderPage(<Host initial={pair} blocks={[fetcher, sender]} selected={2} readOnly />);

    expect(screen.queryByRole('button', { name: /^Bind / })).not.toBeInTheDocument();
  });

  it('labels a mismatched edge with text and marks the chip invalid, from the server issue', async () => {
    const bound = [
      pair[0],
      {
        ...pair[1],
        dependsOnStepIds: [1],
        kindConfig: { ...pair[1].kindConfig, arguments: { row: '{{output:1:rows.json}}' } },
      },
    ];
    const issue: WorkflowIssue = {
      severity: 'error',
      code: 'type_mismatch',
      stepKey: '2',
      field: 'arguments.row',
      message: 'row expects row but rows is list<row>. Use a For each step.',
    };
    renderPage(<Host initial={bound} blocks={[fetcher, sender]} issues={[issue]} />);

    expect(await screen.findByText('Type mismatch')).toBeInTheDocument();
    expect(screen.getByRole('group', { name: 'Input row, type row, bound, type mismatch' })).toHaveTextContent(
      '(mismatch)',
    );
    expect(screen.getByRole('group', { name: 'Input loose, type any' })).toBeInTheDocument();
  });

  it('lists a node’s problems in a popover, errors first, and applies a fix from it', async () => {
    const issues: WorkflowIssue[] = [
      { severity: 'warning', code: 'w', stepKey: '3', field: 'instructions', message: 'Maybe slow.' },
      {
        severity: 'error',
        code: 'not_upstream',
        stepKey: '3',
        field: 'instructions',
        message: 'Draft spec is not upstream.',
        fix: { kind: 'add_dependency', stepKey: '1' },
      },
    ];
    const lone = [steps[0], step(3, 'Cool off', { kind: 'wait', kindConfig: { delaySeconds: 60 } })];
    renderPage(
      <Host initial={lone} issues={issues} fixLabel={(fix: IssueFix) => `Run after Draft spec (${fix.kind})`} />,
    );

    const badge = screen.getByRole('button', { name: /1 error.*1 warning/ });
    await userEvent.click(badge);
    const list = await screen.findByRole('list', { name: 'Problems with Cool off' });
    const items = within(list).getAllByRole('listitem');
    expect(items[0]).toHaveTextContent('Draft spec is not upstream.');
    expect(within(items[0]).getByLabelText('Error')).toBeInTheDocument();
    expect(items[1]).toHaveTextContent('Maybe slow.');
    expect(within(items[1]).getByLabelText('Warning')).toBeInTheDocument();

    await userEvent.click(within(items[0]).getByRole('button', { name: 'Run after Draft spec (add_dependency)' }));

    expect(await screen.findByRole('group', { name: /^Wait Cool off, runs after Draft spec/ })).toBeInTheDocument();
  });

  it('keeps Delete inside the problems popover from removing the selected step', async () => {
    const onRequestDelete = vi.fn();
    const issues: WorkflowIssue[] = [
      { severity: 'error', code: 'x', stepKey: '1', field: 'instructions', message: 'Broken.' },
    ];
    renderPage(<Host initial={steps} issues={issues} selected={1} onRequestDelete={onRequestDelete} />);

    await userEvent.click(screen.getByRole('button', { name: /1 error/ }));
    await screen.findByRole('list', { name: 'Problems with Draft spec' });
    await userEvent.keyboard('{Delete}{Backspace}');

    expect(onRequestDelete).not.toHaveBeenCalled();
  });
});

describe('Projects/Workflows/canvas/WorkflowCanvas composite blocks', () => {
  let restoreResizeObserver: () => void;
  beforeEach(() => {
    restoreResizeObserver = reportResizes();
  });
  afterEach(() => restoreResizeObserver());

  const INSTANCE = '11111111-1111-4111-8111-111111111111';
  const flow = buildCompositeBlock();
  const rowsFile = [{ name: 'rows.json', assetType: 'file' as const, required: true }];
  const inner = (id: number, name: string, node: string, patch: Partial<Step> = {}) =>
    step(id, name, { composite: { ref: flow.key, instance: INSTANCE, node }, ...patch });
  const grouped = () => [
    step(1, 'Fetch rows', {
      kind: 'action',
      kindConfig: { target: 'mcp_tool', block: 'fetch', arguments: {}, effect: 'read' },
      outputAssetSpecs: rowsFile,
    }),
    inner(2, 'Summarise', 'summarise', { dependsOnStepIds: [1], budgetCents: 40 }),
    inner(3, 'Send invoice', 'send_invoice', {
      kind: 'action',
      kindConfig: { target: 'rest_operation', arguments: { body: '' }, effect: 'send' },
      budgetCents: 25,
      dependsOnStepIds: [2],
    }),
    step(4, 'After', { dependsOnStepIds: [3] }),
  ];
  const blocks = [fetchBlock, flow];
  const collapsed = 'Group Invoice flow, 2 steps, 0 problems, collapsed';

  it('draws an instance as one collapsed node with its ports, caps and no inner step', async () => {
    renderPage(<Host initial={grouped()} blocks={blocks} />);

    const node = screen.getByRole('group', { name: collapsed });
    expect(node).toHaveTextContent('Invoice flow');
    expect(node).toHaveTextContent('caps up to $0.65');
    expect(within(node).getByRole('group', { name: 'Input invoice, type string, not connected' })).toHaveTextContent(
      'not connected',
    );
    expect(within(node).getByRole('group', { name: 'Output sent, type string' })).toBeInTheDocument();
    expect(screen.queryByRole('group', { name: /Summarise/ })).not.toBeInTheDocument();
    expect(await screen.findByLabelText('Invoice flow runs after Fetch rows')).toBeInTheDocument();
  });

  it('says when a newer version of the block is available', () => {
    renderPage(<Host initial={grouped()} blocks={[...blocks, buildCompositeBlock({ key: 'local/invoice-flow@2' })]} />);

    expect(screen.getByRole('group', { name: collapsed })).toHaveTextContent('v2 available');
  });

  it('gathers the problems of the inner steps on the node and lists each under its step', async () => {
    renderPage(
      <Host
        initial={grouped()}
        blocks={blocks}
        issues={[
          {
            severity: 'error',
            code: 'missing_input',
            stepKey: '2',
            field: 'instructions',
            message: 'No output named plan.',
          },
          { severity: 'warning', code: 'unused', stepKey: '3', field: 'instructions', message: 'Nothing reads this.' },
        ]}
      />,
    );

    const node = screen.getByRole('group', { name: 'Group Invoice flow, 2 steps, 2 problems, collapsed' });
    await userEvent.click(within(node).getByRole('button', { name: /1 error/ }));

    const list = await screen.findByRole('list', { name: 'Problems with Summarise' });
    expect(list).toHaveTextContent('No output named plan.');
    expect(screen.getByRole('list', { name: 'Problems with Send invoice' })).toHaveTextContent('Nothing reads this.');
  });

  it('expands to the inner steps in a frame and collapses again, announcing and keeping focus', async () => {
    const announce = vi.fn();
    renderPage(<Host initial={grouped()} blocks={blocks} announce={announce} />);

    await userEvent.click(screen.getByRole('button', { name: 'Expand Invoice flow' }));

    expect(
      await screen.findByRole('group', { name: nodeName('Session', 'Summarise', 'Fetch rows') }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole('group', { name: 'Group Invoice flow, 2 steps, 0 problems, expanded' }),
    ).toBeInTheDocument();
    expect(announce).toHaveBeenCalledWith('Invoice flow expanded');
    await waitFor(() =>
      expect(screen.getByRole('group', { name: 'Group Invoice flow, 2 steps, 0 problems, expanded' })).toHaveFocus(),
    );

    await userEvent.click(screen.getByRole('button', { name: 'Collapse Invoice flow' }));

    expect(await screen.findByRole('group', { name: collapsed })).toBeInTheDocument();
    expect(screen.queryByRole('group', { name: /Summarise/ })).not.toBeInTheDocument();
  });

  it('ungroups: the steps stay, only their provenance goes', async () => {
    const onStepsChange = vi.fn();
    renderPage(<Host initial={grouped()} blocks={blocks} onStepsChange={onStepsChange} />);

    await userEvent.click(screen.getByRole('button', { name: 'Ungroup Invoice flow' }));

    const next = onStepsChange.mock.calls[0][0](grouped()) as Step[];
    expect(next.map((s) => s.composite)).toEqual([null, null, null, null]);
    expect(next.map((s) => s.name)).toEqual(['Fetch rows', 'Summarise', 'Send invoice', 'After']);
    expect(await screen.findByRole('group', { name: /^Session Summarise/ })).toBeInTheDocument();
    expect(screen.queryByRole('group', { name: /^Group / })).not.toBeInTheDocument();
  });

  it('binds an in port: writes the argument the block names, adds the dependency and says so', async () => {
    const announce = vi.fn();
    const onStepsChange = vi.fn();
    renderPage(<Host initial={grouped()} blocks={blocks} announce={announce} onStepsChange={onStepsChange} />);

    await userEvent.click(screen.getByRole('button', { name: 'Bind invoice of Invoice flow to…' }));
    const menu = await screen.findByRole('menu');
    await userEvent.click(within(menu).getByRole('menuitem', { name: 'Fetch rows: rows (list<row>)' }));

    const next = onStepsChange.mock.calls[0][0](grouped()) as Step[];
    const sender = next.find((s) => s.id === 3);
    expect(sender?.kindConfig.arguments).toEqual({ body: '{{output:1:rows.json}}' });
    expect(sender?.dependsOnStepIds).toEqual([2, 1]);
    expect(announce).toHaveBeenCalledWith('Invoice flow now reads invoice from Fetch rows: rows');
    expect(await screen.findByRole('group', { name: 'Input invoice, type string' })).toBeInTheDocument();
  });

  it('offers neither Ungroup nor Bind while read-only, and still shows the group', () => {
    renderPage(<Host initial={grouped()} blocks={blocks} readOnly />);

    expect(screen.getByRole('group', { name: collapsed })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Expand Invoice flow' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Ungroup Invoice flow' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /^Bind / })).not.toBeInTheDocument();
  });

  it('never deletes a group with the Delete key', async () => {
    const onRequestDelete = vi.fn();
    renderPage(<Host initial={grouped()} blocks={blocks} onRequestDelete={onRequestDelete} />);

    screen.getByRole('group', { name: collapsed }).focus();
    await userEvent.keyboard('{Delete}');

    expect(onRequestDelete).not.toHaveBeenCalled();
  });

  it('moves every step of a group with the group, from the keyboard', async () => {
    renderPage(<Host initial={grouped()} blocks={blocks} />);
    const before = [draftPosition('Summarise'), draftPosition('Send invoice')];

    const user = userEvent.setup();
    screen.getByRole('group', { name: collapsed }).focus();
    await user.keyboard('{Enter}');
    await user.keyboard('{ArrowRight>}');
    await user.keyboard('{/ArrowRight}');

    const shifted = (position: string | undefined) => Number(position?.split(',')[0]);
    await waitFor(() => expect(draftPosition('Summarise')).not.toBe('auto'));
    expect(before).toEqual(['auto', 'auto']);
    expect(shifted(draftPosition('Send invoice')) - shifted(draftPosition('Summarise'))).toBeGreaterThan(0);
  });
});

describe('Projects/Workflows/canvas/WorkflowCanvas a step inside a collapsed group', () => {
  let restoreResizeObserver: () => void;
  beforeEach(() => {
    restoreResizeObserver = reportResizes();
  });
  afterEach(() => restoreResizeObserver());

  const INSTANCE = '11111111-1111-4111-8111-111111111111';
  const flow = buildCompositeBlock();
  const inner = (id: number, name: string, node: string, patch: Partial<Step> = {}) =>
    step(id, name, { composite: { ref: flow.key, instance: INSTANCE, node }, ...patch });
  const grouped = () => [
    step(1, 'Fetch rows'),
    inner(2, 'Summarise', 'summarise', { dependsOnStepIds: [1] }),
    inner(3, 'Send invoice', 'send_invoice', { dependsOnStepIds: [2] }),
  ];
  const palette = () => screen.getByRole('list', { name: 'Steps' });

  it('opens the group that holds the selected step, so the step is on the canvas', async () => {
    renderPage(<Host initial={grouped()} blocks={[flow]} selected={2} />);

    expect(await screen.findByRole('group', { name: /^Session Summarise/ })).toBeInTheDocument();
    expect(
      screen.getByRole('group', { name: 'Group Invoice flow, 2 steps, 0 problems, expanded' }),
    ).toBeInTheDocument();
  });

  it('lets the person collapse that group again without opening it a second time', async () => {
    renderPage(<Host initial={grouped()} blocks={[flow]} selected={2} />);

    await userEvent.click(await screen.findByRole('button', { name: 'Collapse Invoice flow' }));

    expect(await screen.findByRole('group', { name: /collapsed/ })).toBeInTheDocument();
  });

  it('adds from the palette after the selected inner step and focuses the new node', async () => {
    renderPage(<Host initial={grouped()} blocks={[flow]} selected={2} />);

    await userEvent.click(within(palette()).getByRole('button', { name: 'Approval' }));

    const added = await screen.findByRole('group', { name: /^Approval Approval 4, runs after Summarise/ });
    await waitFor(() => expect(added).toHaveFocus());
  });
});

describe('Projects/Workflows/canvas/WorkflowCanvas Save as block', () => {
  let restoreResizeObserver: () => void;
  beforeEach(() => {
    restoreResizeObserver = reportResizes();
  });
  afterEach(() => restoreResizeObserver());

  const plain = [
    step(1, 'Fetch'),
    step(2, 'Summarise', { dependsOnStepIds: [1] }),
    step(3, 'Send', { dependsOnStepIds: [2] }),
  ];

  function show(props: { onSelect?: (id: number | null) => void; dirty?: boolean; readOnly?: boolean } = {}) {
    renderPage(
      <div style={{ width: 1200, height: 600 }}>
        <WorkflowCanvas
          steps={plain}
          issues={[]}
          blocks={[]}
          actionsEnabled
          selection={null}
          readOnly={props.readOnly ?? false}
          onSelect={props.onSelect ?? vi.fn()}
          onStepsChange={vi.fn()}
          projectId={7}
          workflowId={3}
          dirty={props.dirty ?? false}
        />
      </div>,
    );
  }

  it('picks steps with Shift+click without opening them, and opens the dialog with them checked', async () => {
    const onSelect = vi.fn();
    show({ onSelect });

    fireEvent.click(screen.getByRole('group', { name: nodeName('Session', 'Fetch') }), { shiftKey: true });
    fireEvent.click(screen.getByRole('group', { name: nodeName('Session', 'Send', 'Summarise') }), { shiftKey: true });

    expect(onSelect).not.toHaveBeenCalled();
    expect(screen.getByText('2 steps picked')).toBeInTheDocument();
    expect(screen.getByRole('group', { name: /^Session Fetch.*picked for Save as block/ })).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Save as block' }));

    const dialog = await screen.findByRole('dialog', { name: 'Save as block' });
    expect(within(dialog).getByRole('checkbox', { name: 'Fetch' })).toBeChecked();
    expect(within(dialog).getByRole('checkbox', { name: 'Summarise' })).not.toBeChecked();
    expect(within(dialog).getByRole('checkbox', { name: 'Send' })).toBeChecked();
  });

  it('lets a person who cannot use the mouse open the dialog with nothing picked, and pick there', async () => {
    show();

    await userEvent.click(screen.getByRole('button', { name: 'Save as block' }));

    const dialog = await screen.findByRole('dialog', { name: 'Save as block' });
    expect(within(dialog).getAllByRole('checkbox')).toHaveLength(3);
    expect(
      within(dialog)
        .getAllByRole('checkbox')
        .some((box) => (box as HTMLInputElement).checked),
    ).toBe(false);
  });

  it('is not offered while read-only', () => {
    show({ readOnly: true });

    expect(screen.queryByRole('button', { name: 'Save as block' })).not.toBeInTheDocument();
  });

  it('a plain click still opens the step and lets go of the picks', async () => {
    const onSelect = vi.fn();
    show({ onSelect });
    fireEvent.click(screen.getByRole('group', { name: nodeName('Session', 'Fetch') }), { shiftKey: true });

    fireEvent.click(screen.getByRole('group', { name: /^Session Summarise/ }));

    expect(onSelect).toHaveBeenCalledWith(2);
    expect(screen.queryByText('1 step picked')).not.toBeInTheDocument();
  });
  it('does not let a Shift+click leave the keyboard unable to select', async () => {
    const onSelect = vi.fn();
    show({ onSelect });
    fireEvent.click(screen.getByRole('group', { name: nodeName('Session', 'Fetch') }), { shiftKey: true });

    screen.getByRole('group', { name: /^Session Summarise/ }).focus();
    await userEvent.keyboard('{Enter}');

    expect(onSelect).toHaveBeenCalledWith(2);
  });

  it('does not count a step that is not saved yet among the steps picked', () => {
    renderPage(
      <div style={{ width: 1200, height: 600 }}>
        <WorkflowCanvas
          steps={[step(1, 'Fetch'), step(-1, 'Brand new', { position: 2 })]}
          issues={[]}
          blocks={[]}
          actionsEnabled
          selection={null}
          readOnly={false}
          onSelect={vi.fn()}
          onStepsChange={vi.fn()}
          projectId={7}
          workflowId={3}
        />
      </div>,
    );

    fireEvent.click(screen.getByRole('group', { name: /^Session Brand new/ }), { shiftKey: true });
    fireEvent.click(screen.getByRole('group', { name: nodeName('Session', 'Fetch') }), { shiftKey: true });

    expect(screen.getByText('1 step picked')).toBeInTheDocument();
  });
});

describe('Projects/Workflows/canvas/WorkflowCanvas inserting a composite from the palette', () => {
  let restoreResizeObserver: () => void;
  beforeEach(() => {
    restoreResizeObserver = reportResizes();
  });
  afterEach(() => restoreResizeObserver());

  it('tells the builder which step is selected, so the block runs after it', async () => {
    const onInsertComposite = vi.fn();
    const flow = buildCompositeBlock();
    renderPage(
      <Host
        initial={steps}
        blocks={[flow]}
        selected={2}
        actionsEnabled
        blocksStatus="ready"
        onInsertComposite={onInsertComposite}
      />,
    );

    await userEvent.click(screen.getByRole('button', { name: /Invoice flow/ }));

    expect(onInsertComposite).toHaveBeenCalledWith(flow, expect.objectContaining({ x: expect.any(Number) }), 2);
  });
});
