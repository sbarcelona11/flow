import '@testing-library/jest-dom/vitest';
import { describe, expect, it, vi } from 'vitest';

import type { ActionTarget, ModuleBlock } from '@/types/generated';
import { renderPage, screen, userEvent, waitFor, within } from 'test/renderPage';

import { ActionStepFields } from './ActionStepFields';

const target: ActionTarget = {
  type: 'rest_operation',
  name: 'list_invoices',
  serverName: 'billing',
  description: null,
  inputSchema: {},
  baseEffect: 'read',
  drifted: false,
  mcpServerId: null,
  tool: null,
  toolId: null,
  apiOperationId: 11,
  httpMethod: 'GET',
  path: '/invoices',
} as ActionTarget;

const block = (overrides: Partial<ModuleBlock> = {}): ModuleBlock => ({
  key: 'local/list-invoices@1',
  label: 'List invoices',
  executor: 'action',
  config: { type: 'object', properties: {} },
  status: 'valid',
  reason: null,
  unresolved: false,
  effect: 'read',
  origin: 'web',
  reviewState: 'reviewed',
  description: null,
  ports: { in: {}, out: { result: 'aixle/record@1' } },
  target: null,
  ...overrides,
});

const config = {
  target: 'rest_operation' as const,
  apiOperationId: 11,
  arguments: { query: { limit: '5' } },
  effect: 'read' as const,
  outputName: 'result.json',
  block: 'local/list-invoices@1',
};

function renderFields({ readOnly = false, blocks = [block()], kindConfig = config } = {}) {
  const onFieldChange = vi.fn();
  renderPage(
    <ActionStepFields
      step={{ id: 1, kindConfig } as never}
      targets={{ status: 'ready', targets: [target] } as never}
      blocks={{ status: 'ready', blocks }}
      projectId={7}
      readOnly={readOnly}
      hasApproval={false}
      onFieldChange={onFieldChange}
      onAddApproval={vi.fn()}
    />,
  );
  return { onFieldChange };
}

describe('Projects/Workflows/ActionStepFields: Detach from block', () => {
  it('drops kindConfig.block after a confirmation and keeps the rest of the call', async () => {
    const { onFieldChange } = renderFields();

    await userEvent.click(screen.getByRole('button', { name: 'Detach from block' }));
    const confirm = await screen.findByRole('dialog', { name: 'Detach from block' });
    expect(
      within(confirm).getByText("This step will keep calling the same operation but won't follow the block any more."),
    ).toBeInTheDocument();
    expect(onFieldChange).not.toHaveBeenCalled();

    await userEvent.click(within(confirm).getByRole('button', { name: 'Detach' }));

    await waitFor(() => expect(onFieldChange).toHaveBeenCalledTimes(1));
    const [field, value] = onFieldChange.mock.calls[0] as [string, Record<string, unknown>];
    expect(field).toBe('kindConfig');
    expect(value).not.toHaveProperty('block');
    expect(value).toMatchObject({ target: 'rest_operation', apiOperationId: 11, outputName: 'result.json' });
  });

  it('does nothing when the confirmation is cancelled', async () => {
    const { onFieldChange } = renderFields();

    await userEvent.click(screen.getByRole('button', { name: 'Detach from block' }));
    await userEvent.click(
      within(await screen.findByRole('dialog', { name: 'Detach from block' })).getByRole('button', { name: 'Cancel' }),
    );

    expect(onFieldChange).not.toHaveBeenCalled();
  });

  it('is the way out of an archived or invalid block', () => {
    renderFields({ blocks: [] });

    expect(screen.getByRole('alert')).toHaveTextContent(/invalid or archived/);
    expect(screen.getByRole('button', { name: 'Detach from block' })).toBeInTheDocument();
  });

  it('says why an invalid block cannot be used', () => {
    renderFields({ blocks: [block({ status: 'invalid', reason: 'Its connector was archived.' })] });

    expect(screen.getByRole('alert')).toHaveTextContent('Its connector was archived.');
  });

  it('is not offered for a step without a block, nor to a viewer', () => {
    renderFields({ kindConfig: { ...config, block: undefined } as never });
    expect(screen.queryByRole('button', { name: 'Detach from block' })).not.toBeInTheDocument();
  });

  it('is hidden when the step is read-only', () => {
    renderFields({ readOnly: true });
    expect(screen.queryByRole('button', { name: 'Detach from block' })).not.toBeInTheDocument();
  });
});
