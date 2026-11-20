import '@testing-library/jest-dom/vitest';
import { router } from '@inertiajs/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { buildApiConnector, buildApiOperation, buildModuleDefinition } from 'test/factories/apiConnector';
import { answerFetch, jsonResponse } from 'test/fetchStub';
import { renderAuthedPage, screen, userEvent, waitFor, within } from 'test/renderPage';

import ApiConnectorsPage from './ApiConnectorsPage';

const project = { id: 7, name: 'Polaris' };
const REVIEW = 'GET /company/projects/7/api_connectors/3/review';
const APPROVE = 'POST /company/projects/7/api_connectors/3/approve';
const REJECT = 'POST /company/projects/7/api_connectors/3/reject';

const connector = buildApiConnector({
  id: 3,
  name: 'billing',
  authType: 'bearer',
  authConfig: { config_item_name: 'STRIPE_KEY' },
  origin: 'builder',
  reviewState: 'waiting',
  enabled: false,
  operationsCount: 2,
});

const reviewPayload = (overrides = {}) => ({
  connector,
  host: 'api.example.com',
  secretBindings: ['STRIPE_KEY → api.example.com'],
  operations: [
    buildApiOperation({
      id: 11,
      name: 'create_invoice',
      httpMethod: 'POST',
      path: '/invoices',
      effect: 'write',
      reviewState: 'waiting',
      reviewDigest: 'op-11',
      inputSchema: { type: 'object' },
    }),
    buildApiOperation({ id: 12, name: 'list_invoices', reviewState: 'waiting', reviewDigest: 'op-12' }),
  ],
  blocks: [buildModuleDefinition({ id: 40, label: 'Bill it', key: 'local/bill-it@1', reviewState: 'waiting' })],
  ...overrides,
});

const open = async () => {
  await userEvent.click(screen.getByRole('button', { name: 'Review billing' }));
  const drawer = await screen.findByRole('dialog', { name: 'Review: billing' });
  await within(drawer).findByText('STRIPE_KEY → api.example.com');
  return drawer;
};

const render = (permissions?: Record<string, boolean>) =>
  renderAuthedPage(<ApiConnectorsPage />, {
    props: {
      project,
      apiConnectors: [connector],
      archivedConnectors: [],
      ...(permissions ? { projectPermissions: permissions } : {}),
    },
  });

describe('Projects/ApiConnectors/ConnectorReviewDrawer', () => {
  beforeEach(() => {
    vi.mocked(router.reload).mockClear();
  });

  it('marks a proposed connector as waiting for review', () => {
    render();

    expect(screen.getByText('Waiting for review')).toBeInTheDocument();
  });

  it('shows which secret goes to which host, the proposed operations and blocks, and the Advanced part shut', async () => {
    answerFetch({ [REVIEW]: reviewPayload() });
    render();

    const drawer = await open();

    expect(within(drawer).getAllByText('/invoices on api.example.com')).toHaveLength(2);
    expect(within(drawer).getByText('create_invoice')).toBeInTheDocument();
    expect(within(drawer).getByText('list_invoices')).toBeInTheDocument();
    expect(within(drawer).getByText('Bill it (local/bill-it@1): waiting for review')).toBeInTheDocument();
    expect(within(drawer).getByRole('button', { name: 'Advanced' })).toHaveAttribute('aria-expanded', 'false');
    expect(within(drawer).queryByText(/"inputSchema"/)).not.toBeInTheDocument();
  });

  it('approves the connector and the operations it shows with their digests, only after the click', async () => {
    const fetchSpy = answerFetch({ [REVIEW]: reviewPayload(), [APPROVE]: {} });
    render();
    const drawer = await open();

    expect(fetchSpy.mock.calls.some(([url]) => String(url).endsWith('/approve'))).toBe(false);
    await userEvent.click(within(drawer).getByRole('button', { name: 'Approve and enable' }));

    await waitFor(() => expect(router.reload).toHaveBeenCalled());
    const call = fetchSpy.mock.calls.find(([url]) => String(url).endsWith('/approve'));
    expect(JSON.parse(String(call?.[1]?.body))).toEqual({
      expectedDigest: 'digest-connector-3',
      operationDigests: { '11': 'op-11', '12': 'op-12' },
    });
  });

  it('tells the reviewer the content changed on a 409 and shows the reloaded version', async () => {
    let loads = 0;
    answerFetch({
      [REVIEW]: () =>
        ++loads === 1
          ? reviewPayload()
          : reviewPayload({ secretBindings: ['OTHER_KEY → evil.example.net'], host: 'evil.example.net' }),
      [APPROVE]: jsonResponse({ error: 'ApiConnector 3 changed after it was shown for review' }, 409),
    });
    render();
    const drawer = await open();

    await userEvent.click(within(drawer).getByRole('button', { name: 'Approve and enable' }));

    expect(await within(drawer).findByText(/This changed while you were looking at it/)).toBeInTheDocument();
    expect(await within(drawer).findByText('OTHER_KEY → evil.example.net')).toBeInTheDocument();
    expect(router.reload).not.toHaveBeenCalled();
  });

  it('rejects the connector on its own click', async () => {
    const fetchSpy = answerFetch({ [REVIEW]: reviewPayload(), [REJECT]: {} });
    render();
    const drawer = await open();

    await userEvent.click(within(drawer).getByRole('button', { name: 'Reject' }));

    await waitFor(() => expect(router.reload).toHaveBeenCalled());
    expect(fetchSpy.mock.calls.some(([url]) => String(url).endsWith('/reject'))).toBe(true);
  });

  it('gives a viewer the summary and no buttons to decide', async () => {
    answerFetch({ [REVIEW]: reviewPayload() });
    render({ canExecute: false, canManage: false, canManageCompany: false });

    await userEvent.click(screen.getByRole('button', { name: 'Details of billing' }));
    const drawer = await screen.findByRole('dialog', { name: 'Review: billing' });
    await within(drawer).findByText('STRIPE_KEY → api.example.com');

    expect(within(drawer).queryByRole('button', { name: /Approve/ })).not.toBeInTheDocument();
    expect(within(drawer).queryByRole('button', { name: 'Reject' })).not.toBeInTheDocument();
  });

  it('shows text from the API as plain text', async () => {
    const hostile = '<script>alert(1)</script> [x](http://evil.example)';
    answerFetch({
      [REVIEW]: reviewPayload({
        operations: [
          buildApiOperation({
            id: 11,
            name: 'create_invoice',
            summary: hostile,
            reviewState: 'waiting',
            reviewDigest: 'op-11',
          }),
        ],
      }),
    });
    render();
    const drawer = await open();

    expect(within(drawer).getByText(hostile)).toBeInTheDocument();
    expect(drawer.querySelector('script')).toBeNull();
    expect(drawer.querySelector('a')).toBeNull();
  });
});
