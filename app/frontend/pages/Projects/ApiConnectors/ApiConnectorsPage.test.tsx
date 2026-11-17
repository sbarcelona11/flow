import '@testing-library/jest-dom/vitest';
import { router } from '@inertiajs/react';
import { describe, expect, it } from 'vitest';

import { buildApiConnector } from 'test/factories/apiConnector';
import { renderAuthedPage, screen, userEvent } from 'test/renderPage';

import ApiConnectorsPage from './ApiConnectorsPage';

const project = { id: 7, name: 'Polaris' };

describe('Projects/ApiConnectors/ApiConnectorsPage', () => {
  it('lists the connectors with their host, auth and operation count', () => {
    renderAuthedPage(<ApiConnectorsPage />, {
      props: {
        project,
        apiConnectors: [buildApiConnector({ name: 'billing', authType: 'bearer', operationsCount: 4 })],
        archivedConnectors: [],
      },
    });

    expect(screen.getByText('billing')).toBeInTheDocument();
    expect(screen.getByText('https://api.example.com')).toBeInTheDocument();
    expect(screen.getByText('Bearer token')).toBeInTheDocument();
    expect(screen.getByText('4')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Add REST API' })).toHaveAttribute(
      'href',
      '/company/projects/7/api_connectors/new',
    );
  });

  it('shows the REST APIs tab as selected next to MCP servers', () => {
    renderAuthedPage(<ApiConnectorsPage />, {
      props: { project, apiConnectors: [], archivedConnectors: [] },
    });

    expect(screen.getByRole('tab', { name: 'REST APIs' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByRole('tab', { name: 'MCP servers' })).toHaveAttribute('aria-selected', 'false');
    expect(screen.getByText('No REST APIs configured')).toBeInTheDocument();
  });

  it('archives a connector and restores an archived one', async () => {
    renderAuthedPage(<ApiConnectorsPage />, {
      props: {
        project,
        apiConnectors: [buildApiConnector({ id: 3, name: 'billing' })],
        archivedConnectors: [buildApiConnector({ id: 4, name: 'old_api', archivedAt: '2026-01-01T00:00:00Z' })],
      },
    });

    await userEvent.click(screen.getByRole('button', { name: 'Archive billing' }));
    expect(router.post).toHaveBeenCalledWith('/company/projects/7/api_connectors/3/archive');

    await userEvent.click(screen.getByRole('radio', { name: /Archived/ }));
    await userEvent.click(screen.getByRole('button', { name: 'Restore old_api' }));
    expect(router.post).toHaveBeenCalledWith('/company/projects/7/api_connectors/4/unarchive');
  });
});
