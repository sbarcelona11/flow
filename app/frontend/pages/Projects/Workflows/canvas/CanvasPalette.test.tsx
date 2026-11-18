import '@testing-library/jest-dom/vitest';
import { describe, expect, it, vi } from 'vitest';

import type { ModuleBlock } from '@/types/generated';
import { renderPage, screen, userEvent, within } from 'test/renderPage';

import type { Blocks } from '../useBlocks';

import { CanvasPalette } from './CanvasPalette';

const block = (key: string, patch: Partial<ModuleBlock> = {}): ModuleBlock => ({
  key,
  label: key,
  executor: 'action',
  config: {},
  origin: 'web',
  reviewState: 'reviewed',
  status: 'valid',
  reason: null,
  unresolved: false,
  effect: 'write',
  description: null,
  ports: { in: {}, out: {} },
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
  ...patch,
});

const ready = (blocks: ModuleBlock[]): Blocks => ({ status: 'ready', blocks });

function show(overrides: Partial<Parameters<typeof CanvasPalette>[0]> = {}) {
  const props = {
    actionsEnabled: true,
    blocks: ready([]),
    onWantBlocks: vi.fn(),
    onAdd: vi.fn(),
    onAddBlock: vi.fn(),
    readOnly: false,
    ...overrides,
  };
  renderPage(<CanvasPalette {...props} />);
  return props;
}

describe('Projects/Workflows/canvas/CanvasPalette', () => {
  it('lists the step kinds as buttons, with Action only when action steps are enabled', () => {
    show();
    const steps = screen.getByRole('list', { name: 'Steps' });
    expect(
      within(steps)
        .getAllByRole('button')
        .map((b) => b.textContent),
    ).toEqual(['Session', 'Approval', 'Wait', 'Action']);
  });

  it('has no Action entry and no Blocks section without the flag, and never asks for blocks', () => {
    const props = show({ actionsEnabled: false });

    expect(screen.queryByRole('button', { name: 'Action' })).not.toBeInTheDocument();
    expect(screen.queryByRole('list', { name: 'Blocks' })).not.toBeInTheDocument();
    expect(screen.queryByRole('textbox', { name: 'Search blocks' })).not.toBeInTheDocument();
    expect(props.onWantBlocks).not.toHaveBeenCalled();
  });

  it('asks for the blocks when it opens and lists only valid action blocks, with their effect', () => {
    const props = show({
      blocks: ready([
        block('File a bug', { effect: 'send' }),
        block('Broken', { status: 'invalid', target: null }),
        block('Ask someone', { executor: 'agent', target: null }),
      ]),
    });

    expect(props.onWantBlocks).toHaveBeenCalled();
    const list = screen.getByRole('list', { name: 'Blocks' });
    expect(within(list).getAllByRole('button')).toHaveLength(1);
    expect(within(list).getByRole('button', { name: 'File a bug Send' })).toBeInTheDocument();
  });

  it('filters blocks by label or description', async () => {
    show({
      blocks: ready([
        block('File a bug', { description: 'Opens an issue in Linear' }),
        block('Send invoice', { description: 'Mails the customer' }),
      ]),
    });

    await userEvent.type(screen.getByRole('textbox', { name: 'Search blocks' }), 'linear');
    const list = screen.getByRole('list', { name: 'Blocks' });
    expect(
      within(list)
        .getAllByRole('button')
        .map((b) => b.textContent),
    ).toEqual(['File a bug Write']);

    await userEvent.clear(screen.getByRole('textbox', { name: 'Search blocks' }));
    await userEvent.type(screen.getByRole('textbox', { name: 'Search blocks' }), 'nothing like it');
    expect(screen.getByText('No block matches.')).toBeInTheDocument();
  });

  it.each([
    ['loading', 'Loading blocks…'],
    ['error', 'The blocks could not be loaded.'],
  ] as const)('says so while the blocks are %s', (status, text) => {
    show({ blocks: { status, blocks: [] } });
    expect(screen.getByText(text)).toBeInTheDocument();
  });

  it('says when the project has no blocks', () => {
    show();
    expect(screen.getByText('No blocks are available in this project.')).toBeInTheDocument();
  });

  it('shows a block label as text, not markup', () => {
    show({ blocks: ready([block('<b>Bold</b>', { description: '<i>x</i>' })]) });
    expect(screen.getByRole('button', { name: '<b>Bold</b> Write' })).toBeInTheDocument();
  });

  it('reports the kind or block that was activated', async () => {
    const file = block('File a bug');
    const props = show({ blocks: ready([file]) });

    await userEvent.click(screen.getByRole('button', { name: 'Approval' }));
    await userEvent.click(screen.getByRole('button', { name: 'File a bug Write' }));

    expect(props.onAdd).toHaveBeenCalledWith('approval');
    expect(props.onAddBlock).toHaveBeenCalledWith(file);
  });

  it('collapses and expands', async () => {
    show();

    await userEvent.click(screen.getByRole('button', { name: 'Hide palette' }));
    expect(screen.queryByRole('button', { name: 'Approval' })).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Show palette' }));
    expect(screen.getByRole('button', { name: 'Approval' })).toBeInTheDocument();
  });

  it('renders nothing while read-only', () => {
    const props = show({ readOnly: true });

    expect(screen.queryByRole('button')).not.toBeInTheDocument();
    expect(props.onWantBlocks).not.toHaveBeenCalled();
  });
});
