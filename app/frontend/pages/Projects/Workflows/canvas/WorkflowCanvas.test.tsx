import '@testing-library/jest-dom/vitest';
import { describe, expect, it, vi } from 'vitest';

import type { Step } from '@/types/generated';
import { fireEvent, renderPage, screen, userEvent } from 'test/renderPage';

import { draftStep } from '../builderDraft';
import type { WorkflowIssue } from '../dataFlow';

import WorkflowCanvas from './WorkflowCanvas';

const step = (id: number, name: string, patch: Partial<Step> = {}): Step => ({
  ...draftStep([], name),
  id,
  position: id,
  ...patch,
});

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
