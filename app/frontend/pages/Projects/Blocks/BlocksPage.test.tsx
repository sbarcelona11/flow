import '@testing-library/jest-dom/vitest';
import { router } from '@inertiajs/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { buildModuleDefinition } from 'test/factories/apiConnector';
import { answerFetch, jsonResponse } from 'test/fetchStub';
import { renderAuthedPage, screen, userEvent, waitFor, within } from 'test/renderPage';

import BlocksPage from './BlocksPage';

const project = { id: 7, name: 'Polaris' };
const SHOW = 'GET /company/projects/7/module_definitions/31';
const APPROVE = 'POST /company/projects/7/module_definitions/31/approve';
const REJECT = 'POST /company/projects/7/module_definitions/31/reject';

const operation = {
  id: 11,
  name: 'create_invoice',
  summary: 'Create an invoice',
  effect: 'write' as const,
  httpMethod: 'POST',
  path: '/invoices',
  connectorName: 'billing',
  host: 'api.example.com',
  secretBindings: ['STRIPE_KEY → api.example.com'],
};

const manifest = {
  kind: 'block',
  slug: 'create-invoice',
  executor: 'action',
  config: { type: 'object', properties: { body: { type: 'object' } } },
  ports: { in: {}, out: { result: 'aixle/record@1' } },
};

const waiting = buildModuleDefinition({
  reviewState: 'waiting',
  enabled: false,
  origin: 'builder',
  originSessionId: 123,
  reviewedAt: null,
  createdBy: { id: 1, name: 'Ada' },
});

const shown = (overrides = {}) => ({
  ...waiting,
  manifest,
  calls: {
    resolved: true,
    connector: 'billing',
    operation: 'create_invoice',
    method: 'POST',
    path: '/invoices',
    host: 'api.example.com',
    effect: 'write',
    connectorState: 'reviewed',
    secretBindings: ['STRIPE_KEY → api.example.com'],
  },
  ...overrides,
});

const render = (props = {}, permissions: Record<string, boolean> = {}) =>
  renderAuthedPage(<BlocksPage />, {
    props: { project, definitions: [waiting], operations: [operation], truncated: false, ...props, ...permissions },
  });

describe('Projects/Blocks/BlocksPage', () => {
  beforeEach(() => {
    vi.mocked(router.reload).mockClear();
  });

  it('is the third tab next to MCP servers and REST APIs, and selects Blocks', () => {
    render({ definitions: [] });

    expect(screen.getByRole('tab', { name: 'Blocks' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByRole('tab', { name: 'REST APIs' })).toHaveAttribute('aria-selected', 'false');
    expect(screen.getByText('No blocks yet')).toBeInTheDocument();
  });

  it('groups blocks by status and says who proposed what', () => {
    render({
      definitions: [
        waiting,
        buildModuleDefinition({ id: 32, slug: 'live', key: 'local/live@1', label: 'Live one' }),
        buildModuleDefinition({ id: 33, label: 'Off one', enabled: false }),
        buildModuleDefinition({ id: 34, label: 'Broken one', status: 'invalid', reason: 'Connector gone' }),
        buildModuleDefinition({ id: 35, label: 'Old one', archivedAt: '2026-01-01T00:00:00Z' }),
      ],
    });

    for (const title of ['Waiting for review', 'Enabled', 'Disabled', 'Invalid', 'Archived']) {
      expect(screen.getByRole('region', { name: title })).toBeInTheDocument();
    }
    expect(screen.getByText('Proposed by Aixle Builder in session #123 (Ada)')).toBeInTheDocument();
    expect(screen.getByText('Connector gone')).toBeInTheDocument();
  });

  it('shows what a waiting block calls, which secret goes where and the effect, with the manifest shut', async () => {
    answerFetch({ [SHOW]: shown() });
    render();

    await userEvent.click(screen.getByRole('button', { name: 'Review Create invoice' }));

    const drawer = await screen.findByRole('dialog', { name: 'Review: Create invoice' });
    expect(await within(drawer).findByText('/invoices on api.example.com')).toBeInTheDocument();
    expect(within(drawer).getByText('POST')).toBeInTheDocument();
    expect(within(drawer).getByText('STRIPE_KEY → api.example.com')).toBeInTheDocument();
    expect(within(drawer).getByText('Write')).toBeInTheDocument();
    expect(within(drawer).getByText('Settings: body')).toBeInTheDocument();
    expect(within(drawer).getByText('Gives: result: aixle/record@1')).toBeInTheDocument();
    expect(within(drawer).getByRole('button', { name: 'Advanced' })).toHaveAttribute('aria-expanded', 'false');
    expect(within(drawer).queryByText(/"executor"/)).not.toBeInTheDocument();

    await userEvent.click(within(drawer).getByRole('button', { name: 'Advanced' }));
    expect(within(drawer).getByText(/"executor": "action"/)).toBeInTheDocument();
  });

  it('approves only on the click, sending the digest it displayed', async () => {
    const fetchSpy = answerFetch({ [SHOW]: shown(), [APPROVE]: { ...waiting, reviewState: 'reviewed' } });
    render();
    await userEvent.click(screen.getByRole('button', { name: 'Review Create invoice' }));
    const drawer = await screen.findByRole('dialog', { name: 'Review: Create invoice' });
    await within(drawer).findByText('/invoices on api.example.com');

    expect(fetchSpy.mock.calls.some(([url]) => String(url).endsWith('/approve'))).toBe(false);
    await userEvent.click(within(drawer).getByRole('button', { name: 'Approve and enable' }));

    await waitFor(() => expect(router.reload).toHaveBeenCalled());
    const call = fetchSpy.mock.calls.find(([url]) => String(url).endsWith('/approve'));
    expect(JSON.parse(String(call?.[1]?.body))).toEqual({ expectedDigest: 'digest-block-31' });
  });

  it('reloads the block and says it changed when the server answers 409', async () => {
    let loads = 0;
    answerFetch({
      [SHOW]: () => (++loads === 1 ? shown() : shown({ reviewDigest: 'digest-new', label: 'Create invoice' })),
      [APPROVE]: jsonResponse({ error: 'ModuleDefinition 31 changed after it was shown for review' }, 409),
    });
    render();
    await userEvent.click(screen.getByRole('button', { name: 'Review Create invoice' }));
    const drawer = await screen.findByRole('dialog', { name: 'Review: Create invoice' });
    await within(drawer).findByText('/invoices on api.example.com');

    await userEvent.click(within(drawer).getByRole('button', { name: 'Approve and enable' }));

    expect(await within(drawer).findByText(/This changed while you were looking at it/)).toBeInTheDocument();
    expect(loads).toBe(2);
    expect(router.reload).not.toHaveBeenCalled();
  });

  it('rejects on its own click', async () => {
    const fetchSpy = answerFetch({ [SHOW]: shown(), [REJECT]: {} });
    render();
    await userEvent.click(screen.getByRole('button', { name: 'Review Create invoice' }));
    const drawer = await screen.findByRole('dialog', { name: 'Review: Create invoice' });
    await within(drawer).findByText('/invoices on api.example.com');

    await userEvent.click(within(drawer).getByRole('button', { name: 'Reject' }));

    await waitFor(() => expect(router.reload).toHaveBeenCalled());
    expect(fetchSpy.mock.calls.some(([url]) => String(url).endsWith('/reject'))).toBe(true);
  });

  it('renders everything the manifest says as plain text', async () => {
    const hostile = '<img src=x onerror=alert(1)> **bold** [link](http://evil.example)';
    answerFetch({ [SHOW]: shown({ description: hostile, label: 'Create invoice' }) });
    render();
    await userEvent.click(screen.getByRole('button', { name: 'Review Create invoice' }));
    const drawer = await screen.findByRole('dialog', { name: 'Review: Create invoice' });

    expect(await within(drawer).findByText(hostile)).toBeInTheDocument();
    expect(drawer.querySelector('img')).toBeNull();
    expect(drawer.querySelector('a')).toBeNull();
  });

  it('gives a viewer no action buttons, not even on a waiting block', async () => {
    answerFetch({ [SHOW]: shown() });
    renderAuthedPage(<BlocksPage />, {
      props: {
        project,
        definitions: [waiting, buildModuleDefinition({ id: 32, label: 'Live one' })],
        operations: [operation],
        truncated: false,
        projectPermissions: { canExecute: false, canManage: false, canManageCompany: false },
      },
    });

    expect(screen.queryByRole('button', { name: 'New block' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /^(Disable|Enable|Archive|New version of)/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /^Review / })).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Details of Create invoice' }));
    const drawer = await screen.findByRole('dialog', { name: 'Review: Create invoice' });
    await within(drawer).findByText('/invoices on api.example.com');
    expect(within(drawer).queryByRole('button', { name: 'Approve and enable' })).not.toBeInTheDocument();
    expect(within(drawer).queryByRole('button', { name: 'Reject' })).not.toBeInTheDocument();
  });

  it('enables, disables and archives with their own clicks', async () => {
    const fetchSpy = answerFetch({
      'POST /company/projects/7/module_definitions/32/disable': {},
      'POST /company/projects/7/module_definitions/33/enable': {},
      'POST /company/projects/7/module_definitions/32/archive': {},
    });
    render({
      definitions: [
        buildModuleDefinition({ id: 32, label: 'Live one' }),
        buildModuleDefinition({ id: 33, label: 'Off one', enabled: false }),
      ],
    });

    await userEvent.click(screen.getByRole('button', { name: 'Disable Live one' }));
    await userEvent.click(screen.getByRole('button', { name: 'Enable Off one' }));
    await userEvent.click(screen.getByRole('button', { name: 'Archive Live one' }));
    await userEvent.click(await screen.findByRole('button', { name: 'Archive' }));

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(3));
    expect(fetchSpy.mock.calls.map(([url]) => String(url))).toEqual([
      '/company/projects/7/module_definitions/32/disable',
      '/company/projects/7/module_definitions/33/enable',
      '/company/projects/7/module_definitions/32/archive',
    ]);
  });

  describe('New block dialog', () => {
    const CREATE = 'POST /company/projects/7/module_definitions';

    it('makes a block from an operation after a summary of what it calls', async () => {
      const fetchSpy = answerFetch({ [CREATE]: { ...waiting, warnings: [] } });
      render({ definitions: [] });
      await userEvent.click(screen.getByRole('button', { name: 'New block' }));
      const dialog = await screen.findByRole('dialog', { name: 'New block' });

      await userEvent.click(within(dialog).getByRole('combobox', { name: 'Operation' }));
      await userEvent.click(await screen.findByRole('option', { name: 'create_invoice' }));
      await userEvent.type(within(dialog).getByRole('textbox', { name: 'Label' }), 'Create invoice');
      await userEvent.click(within(dialog).getByRole('button', { name: 'Review' }));

      expect(within(dialog).getByText('/invoices on api.example.com')).toBeInTheDocument();
      expect(within(dialog).getByText('STRIPE_KEY → api.example.com')).toBeInTheDocument();
      expect(fetchSpy).not.toHaveBeenCalled();

      await userEvent.click(within(dialog).getByRole('button', { name: 'Create block' }));

      await waitFor(() => expect(router.reload).toHaveBeenCalled());
      const call = fetchSpy.mock.calls[0];
      expect(JSON.parse(String(call[1]?.body))).toEqual({
        fromOperation: {
          apiOperationId: 11,
          label: 'Create invoice',
          description: '',
          effect: 'write',
          namespace: 'local',
        },
      });
    });

    it('pastes a manifest under Advanced, which replaces the choices', async () => {
      const fetchSpy = answerFetch({ [CREATE]: { ...waiting, warnings: ['One setting was left out.'] } });
      render({ definitions: [] });
      await userEvent.click(screen.getByRole('button', { name: 'New block' }));
      const dialog = await screen.findByRole('dialog', { name: 'New block' });

      expect(within(dialog).queryByRole('textbox', { name: 'Paste a manifest instead' })).not.toBeInTheDocument();
      await userEvent.click(within(dialog).getByRole('button', { name: 'Advanced' }));
      await userEvent.type(within(dialog).getByRole('textbox', { name: 'Paste a manifest instead' }), 'kind: block');
      await userEvent.click(within(dialog).getByRole('button', { name: 'Review' }));
      await userEvent.click(within(dialog).getByRole('button', { name: 'Create block' }));

      expect(await within(dialog).findByText('One setting was left out.')).toBeInTheDocument();
      expect(JSON.parse(String(fetchSpy.mock.calls[0][1]?.body))).toEqual({ manifest: 'kind: block' });
    });

    it('keeps the dialog open with the server refusal', async () => {
      answerFetch({ [CREATE]: jsonResponse({ error: 'slug is not valid' }, 422) });
      render({ definitions: [] });
      await userEvent.click(screen.getByRole('button', { name: 'New block' }));
      const dialog = await screen.findByRole('dialog', { name: 'New block' });
      await userEvent.click(within(dialog).getByRole('button', { name: 'Advanced' }));
      await userEvent.type(within(dialog).getByRole('textbox', { name: 'Paste a manifest instead' }), 'x');
      await userEvent.click(within(dialog).getByRole('button', { name: 'Review' }));
      await userEvent.click(within(dialog).getByRole('button', { name: 'Create block' }));

      expect(await within(dialog).findByText('slug is not valid')).toBeInTheDocument();
    });
  });
});
