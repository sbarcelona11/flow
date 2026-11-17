import '@testing-library/jest-dom/vitest';
import { useState } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { ModuleBlock, Step } from '@/types/generated';
import { reportResizes } from 'test/reactFlowEnvironment';
import { act, fireEvent, renderPage, screen, userEvent, within } from 'test/renderPage';

import { draftBlockStep, draftStep } from '../builderDraft';
import type { WorkflowIssue } from '../dataFlow';

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
  status: 'valid',
  reason: null,
  unresolved: false,
  effect: 'read',
  description: null,
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
          selection={selectedId == null ? null : { mode: 'session', sessionId: selectedId }}
          readOnly={readOnly}
          onSelect={setSelectedId}
          onStepsChange={(updater) => {
            spies.onStepsChange?.(updater);
            setDraft(updater);
          }}
          onRequestDelete={spies.onRequestDelete}
          announce={spies.announce}
        />
      </div>
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

    fireEvent.click(await screen.findByLabelText('Approve spec runs after Draft spec'));
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

  it('highlights the selected node and follows the selection', () => {
    const { rerender } = renderPage(<Host initial={editable} selected={2} />);
    expect(screen.getByRole('group', { name: nodeName('Approval', 'Approve spec', 'Draft spec') })).toHaveClass(
      'selected',
    );
    expect(screen.getByRole('group', { name: nodeName('Session', 'Draft spec') })).not.toHaveClass('selected');

    rerender(<Host key="again" initial={editable} selected={1} />);
    expect(screen.getByRole('group', { name: nodeName('Session', 'Draft spec') })).toHaveClass('selected');
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
