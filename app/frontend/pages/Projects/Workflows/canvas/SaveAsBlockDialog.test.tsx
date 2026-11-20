import '@testing-library/jest-dom/vitest';
import { describe, expect, it, vi } from 'vitest';

import { buildStep } from 'test/factories/step';
import { answerFetch, jsonResponse } from 'test/fetchStub';
import { renderPage, screen, userEvent, within } from 'test/renderPage';

import { SaveAsBlockDialog } from './SaveAsBlockDialog';

const ROUTE = 'POST /company/projects/7/module_definitions/from_steps';

const steps = [
  buildStep({ id: 1, position: 1, name: 'Fetch invoice' }),
  buildStep({ id: 2, position: 2, name: 'Summarise', dependsOnStepIds: [1] }),
  buildStep({ id: 3, position: 3, name: 'Send invoice', dependsOnStepIds: [2] }),
  buildStep({ id: -1, position: 4, name: 'Brand new' }),
];

const created = (overrides: Record<string, unknown> = {}) => ({
  key: 'local/invoice-flow@1',
  label: 'Invoice flow',
  warnings: [],
  step_keys: { '2': 'summarise', '3': 'send_invoice' },
  manifest: {
    graph: {
      steps: [
        { key: 'summarise', name: 'Summarise' },
        { key: 'send_invoice', name: 'Send invoice' },
      ],
    },
  },
  ...overrides,
});

function show(props: Partial<Parameters<typeof SaveAsBlockDialog>[0]> = {}) {
  const all = {
    projectId: 7,
    workflowId: 3,
    steps,
    initialSelected: [],
    dirty: false,
    onClose: vi.fn(),
    onBlockMade: vi.fn(),
    onReplace: vi.fn(),
    ...props,
  };
  renderPage(<SaveAsBlockDialog {...all} />);
  return all;
}

const submit = () => screen.getByRole('button', { name: 'Save as block' });

describe('Projects/Workflows/canvas/SaveAsBlockDialog', () => {
  it('starts with the canvas selection checked and offers every other step to check', () => {
    show({ initialSelected: [2, 3] });

    const dialog = screen.getByRole('dialog', { name: 'Save as block' });
    expect(within(dialog).getByRole('checkbox', { name: 'Summarise' })).toBeChecked();
    expect(within(dialog).getByRole('checkbox', { name: 'Send invoice' })).toBeChecked();
    expect(within(dialog).getByRole('checkbox', { name: 'Fetch invoice' })).not.toBeChecked();
  });

  it('shows a step that is not saved yet, and cannot be picked', () => {
    show({ initialSelected: [-1] });

    expect(screen.getByRole('checkbox', { name: 'Brand new (not saved yet)' })).toBeDisabled();
    expect(screen.getByRole('checkbox', { name: 'Brand new (not saved yet)' })).not.toBeChecked();
  });

  it('asks to save the workflow first while the draft has changes, and sends nothing', async () => {
    answerFetch({ [ROUTE]: created() });
    show({ dirty: true, initialSelected: [2] });

    expect(screen.getByText('Save the workflow first')).toBeInTheDocument();
    await userEvent.type(screen.getByRole('textbox', { name: 'Name' }), 'Invoice flow');

    expect(submit()).toBeDisabled();
    expect(fetch).not.toHaveBeenCalled();
  });

  it('is the keyboard route: check steps, name the block, save', async () => {
    answerFetch({ [ROUTE]: created() });
    const props = show();

    await userEvent.tab();
    await userEvent.click(screen.getByRole('checkbox', { name: 'Summarise' }));
    await userEvent.click(screen.getByRole('checkbox', { name: 'Send invoice' }));
    expect(submit()).toBeDisabled();
    await userEvent.type(screen.getByRole('textbox', { name: 'Name' }), 'Invoice flow');
    await userEvent.type(screen.getByRole('textbox', { name: 'Description' }), 'Bills a customer');
    await userEvent.click(submit());

    expect(await screen.findByText(/Saved as the block Invoice flow \(local\/invoice-flow@1\)/)).toBeInTheDocument();
    const [path, init] = vi.mocked(fetch).mock.calls[0];
    expect(String(path)).toBe('/company/projects/7/module_definitions/from_steps');
    expect(JSON.parse(String(init?.body))).toEqual({
      workflowId: 3,
      stepIds: [2, 3],
      label: 'Invoice flow',
      description: 'Bills a customer',
    });
    expect(props.onBlockMade).toHaveBeenCalledTimes(1);
  });

  it('shows the extractor refusal as it is, and keeps the form', async () => {
    answerFetch({
      [ROUTE]: () =>
        jsonResponse(
          { error: 'Include the approval step Approve in the block: Send invoice (send) must run after it.' },
          422,
        ),
    });
    show({ initialSelected: [3] });
    await userEvent.type(screen.getByRole('textbox', { name: 'Name' }), 'Send flow');

    await userEvent.click(submit());

    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Include the approval step Approve in the block: Send invoice (send) must run after it.',
    );
    expect(screen.getByRole('checkbox', { name: 'Send invoice' })).toBeChecked();
    expect(submit()).toBeEnabled();
  });

  it('shows the warnings as plain text, and replaces the selection by marking the picked steps', async () => {
    answerFetch({ [ROUTE]: created({ warnings: ['Summarise: BMAD can’t be kept <b>here</b>.'] }) });
    const props = show({ initialSelected: [2, 3] });
    await userEvent.type(screen.getByRole('textbox', { name: 'Name' }), 'Invoice flow');
    await userEvent.click(submit());

    expect(await screen.findByRole('list', { name: 'Warnings' })).toHaveTextContent('<b>here</b>');
    await userEvent.click(screen.getByRole('button', { name: 'Replace the selection with the block' }));

    expect(props.onReplace).toHaveBeenCalledWith(
      'local/invoice-flow@1',
      new Map([
        [2, 'summarise'],
        [3, 'send_invoice'],
      ]),
    );
    expect(props.onClose).toHaveBeenCalled();
  });

  it('does not offer to replace the selection when the server did not say which step is which', async () => {
    answerFetch({ [ROUTE]: created({ step_keys: undefined }) });
    show({ initialSelected: [2, 3] });
    await userEvent.type(screen.getByRole('textbox', { name: 'Name' }), 'Invoice flow');
    await userEvent.click(submit());

    expect(await screen.findByText(/Saved as the block/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Replace the selection with the block' })).not.toBeInTheDocument();
    expect(screen.getByRole('status')).toHaveTextContent('did not say which block step');
  });

  it('does not offer to replace the selection when a picked step has no key', async () => {
    answerFetch({ [ROUTE]: created({ step_keys: { '2': 'summarise' } }) });
    show({ initialSelected: [2, 3] });
    await userEvent.type(screen.getByRole('textbox', { name: 'Name' }), 'Invoice flow');
    await userEvent.click(submit());

    expect(await screen.findByText(/Saved as the block/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Replace the selection with the block' })).not.toBeInTheDocument();
  });

  it('pairs steps by the ids the server answered, not by order and name', async () => {
    answerFetch({
      [ROUTE]: created({
        step_keys: { '5': 'approve_second', '6': 'approve_first' },
        // The extractor listed them in the opposite order to the draft, and both are called Approve.
        manifest: {
          graph: {
            steps: [
              { key: 'approve_first', name: 'Approve' },
              { key: 'approve_second', name: 'Approve' },
            ],
          },
        },
      }),
    });
    const props = show({
      steps: [buildStep({ id: 5, position: 1, name: 'Approve' }), buildStep({ id: 6, position: 2, name: 'Approve' })],
      initialSelected: [5, 6],
    });
    await userEvent.type(screen.getByRole('textbox', { name: 'Name' }), 'Two approvals');
    await userEvent.click(submit());

    await userEvent.click(await screen.findByRole('button', { name: 'Replace the selection with the block' }));

    expect(props.onReplace).toHaveBeenCalledWith(
      'local/invoice-flow@1',
      new Map([
        [5, 'approve_second'],
        [6, 'approve_first'],
      ]),
    );
  });

  it('cannot be closed while the block is being saved, so its warnings are not lost', async () => {
    let finish: (response: Response) => void = () => {};
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => new Promise<Response>((resolve) => (finish = resolve)));
    const props = show({ initialSelected: [2] });
    await userEvent.type(screen.getByRole('textbox', { name: 'Name' }), 'Invoice flow');
    await userEvent.click(submit());

    expect(screen.getByRole('button', { name: 'Cancel' })).toBeDisabled();
    await userEvent.keyboard('{Escape}');
    expect(props.onClose).not.toHaveBeenCalled();

    finish(jsonResponse(created()));
    expect(await screen.findByText(/Saved as the block/)).toBeInTheDocument();
  });
});
