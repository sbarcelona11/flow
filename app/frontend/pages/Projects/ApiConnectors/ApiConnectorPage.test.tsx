import '@testing-library/jest-dom/vitest';
import { router } from '@inertiajs/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { buildApiConnector, buildApiOperation } from 'test/factories/apiConnector';
import { answerFetch } from 'test/fetchStub';
import { renderAuthedPage, screen, userEvent, waitFor, within } from 'test/renderPage';

import ApiConnectorPage from './ApiConnectorPage';

const project = { id: 7, name: 'Polaris' };
const PREVIEW = 'POST /company/projects/7/api_connector_imports/preview';

async function choose(label: string, option: string) {
  await userEvent.click(screen.getByRole('combobox', { name: label }));
  await userEvent.click(await screen.findByRole('option', { name: option }));
}

describe('Projects/ApiConnectors/ApiConnectorPage', () => {
  beforeEach(() => {
    vi.mocked(router.post).mockClear();
    vi.mocked(router.patch).mockClear();
  });

  it('creates a connector with bearer auth from a Config Item', async () => {
    renderAuthedPage(<ApiConnectorPage />, {
      props: { project, apiConnector: null, operations: [], configItemNames: ['BILLING_TOKEN', 'OTHER'] },
    });

    await userEvent.type(screen.getByRole('textbox', { name: 'Name' }), 'billing');
    await userEvent.type(screen.getByRole('textbox', { name: 'Base URL' }), 'https://api.example.com');
    await choose('Authentication', 'Bearer token');
    await choose('Config Item', 'BILLING_TOKEN');
    await userEvent.click(screen.getByRole('button', { name: 'Create connector' }));

    await waitFor(() =>
      expect(router.post).toHaveBeenCalledWith(
        '/company/projects/7/api_connectors',
        {
          apiConnector: expect.objectContaining({
            name: 'billing',
            baseUrl: 'https://api.example.com',
            authType: 'bearer',
            authConfig: { config_item_name: 'BILLING_TOKEN' },
          }),
        },
        expect.any(Object),
      ),
    );
  });

  it('shows a server refusal under the field it names', async () => {
    vi.mocked(router.post).mockImplementationOnce((_url, _data, options) => {
      (options as { onError?: (e: Record<string, string>) => void }).onError?.({
        base_url: 'must use https',
      });
    });
    renderAuthedPage(<ApiConnectorPage />, {
      props: { project, apiConnector: null, operations: [], configItemNames: [] },
    });

    await userEvent.type(screen.getByRole('textbox', { name: 'Name' }), 'billing');
    await userEvent.type(screen.getByRole('textbox', { name: 'Base URL' }), 'http://api.example.com');
    await userEvent.click(screen.getByRole('button', { name: 'Create connector' }));

    expect(await screen.findByText('must use https')).toBeInTheDocument();
  });

  describe('operations', () => {
    const edit = (operations = [buildApiOperation()]) =>
      renderAuthedPage(<ApiConnectorPage />, {
        props: { project, apiConnector: buildApiConnector({ id: 3 }), operations, configItemNames: [] },
      });

    it('lists the operations with method, path and effect', () => {
      edit();

      expect(screen.getByText('list_invoices')).toBeInTheDocument();
      expect(screen.getByText('/invoices')).toBeInTheDocument();
      expect(screen.getByText('GET')).toBeInTheDocument();
    });

    it('the effect select starts at write for a POST', async () => {
      edit([]);
      await userEvent.click(screen.getByRole('button', { name: 'Add operation' }));
      const dialog = await screen.findByRole('dialog');

      expect(within(dialog).getByRole('combobox', { name: 'Effect' })).toHaveValue('Read');
      await userEvent.click(within(dialog).getByRole('combobox', { name: 'Method' }));
      await userEvent.click(await screen.findByRole('option', { name: 'POST' }));

      expect(within(dialog).getByRole('combobox', { name: 'Effect' })).toHaveValue('Write');
      await userEvent.click(within(dialog).getByRole('combobox', { name: 'Effect' }));
      expect(screen.queryByRole('option', { name: 'Read' })).not.toBeInTheDocument();
      expect(screen.getByRole('option', { name: 'Irreversible' })).toBeInTheDocument();
    });

    it('prefills the three parameter groups and saves the schema as written', async () => {
      edit([]);
      await userEvent.click(screen.getByRole('button', { name: 'Add operation' }));
      const dialog = await screen.findByRole('dialog');

      const editor = within(dialog).getByRole('textbox', { name: 'Parameters' });
      const prefilled = JSON.parse((editor as HTMLTextAreaElement).value) as { properties: Record<string, unknown> };
      expect(Object.keys(prefilled.properties)).toEqual(['path', 'query', 'body']);

      await userEvent.type(within(dialog).getByRole('textbox', { name: 'Name' }), 'list_things');
      await userEvent.type(within(dialog).getByRole('textbox', { name: 'Path' }), '/things');
      await userEvent.click(within(dialog).getByRole('button', { name: 'Add operation' }));

      expect(router.post).toHaveBeenCalledWith(
        '/company/projects/7/api_connectors/3/api_operations',
        {
          apiOperation: expect.objectContaining({
            name: 'list_things',
            httpMethod: 'GET',
            path: '/things',
            effect: 'read',
            inputSchema: prefilled,
          }),
        },
        expect.any(Object),
      );
    });

    it('saves the cost per call as integer cents from a dollar input', async () => {
      edit([]);
      await userEvent.click(screen.getByRole('button', { name: 'Add operation' }));
      const dialog = await screen.findByRole('dialog');

      await userEvent.type(within(dialog).getByRole('textbox', { name: 'Name' }), 'make_thing');
      await userEvent.type(within(dialog).getByRole('textbox', { name: 'Path' }), '/things');
      await userEvent.type(within(dialog).getByRole('textbox', { name: 'Cost per call (USD)' }), '0.29');
      await userEvent.click(within(dialog).getByRole('button', { name: 'Add operation' }));

      expect(router.post).toHaveBeenCalledWith(
        '/company/projects/7/api_connectors/3/api_operations',
        { apiOperation: expect.objectContaining({ costCents: 29 }) },
        expect.any(Object),
      );
    });

    it('sends null when the cost is empty and shows a stored cost in dollars', async () => {
      edit([buildApiOperation({ costCents: 40 })]);
      await userEvent.click(screen.getByRole('button', { name: 'Edit list_invoices' }));
      const dialog = await screen.findByRole('dialog');
      const field = within(dialog).getByRole('textbox', { name: 'Cost per call (USD)' });

      expect(field).toHaveValue('$0.40');
      await userEvent.clear(field);
      await userEvent.click(within(dialog).getByRole('button', { name: 'Save operation' }));

      expect(router.patch).toHaveBeenCalledWith(
        '/company/projects/7/api_connectors/3/api_operations/11',
        { apiOperation: expect.objectContaining({ costCents: null }) },
        expect.any(Object),
      );
    });

    it('shows invalid parameters JSON inline and does not save', async () => {
      edit([]);
      await userEvent.click(screen.getByRole('button', { name: 'Add operation' }));
      const dialog = await screen.findByRole('dialog');

      const editor = within(dialog).getByRole('textbox', { name: 'Parameters' });
      await userEvent.clear(editor);
      await userEvent.type(editor, '{{ nope');
      await userEvent.type(within(dialog).getByRole('textbox', { name: 'Name' }), 'x');
      await userEvent.type(within(dialog).getByRole('textbox', { name: 'Path' }), '/x');
      await userEvent.click(within(dialog).getByRole('button', { name: 'Add operation' }));

      expect(within(dialog).getByText(/Parameters are not valid JSON/)).toBeInTheDocument();
      expect(router.post).not.toHaveBeenCalled();
    });
  });

  describe('import', () => {
    const DRAFTS = [
      {
        name: 'list_things',
        http_method: 'GET',
        path: '/things',
        summary: null,
        description: null,
        effect: 'read',
        input_schema: { type: 'object', properties: {} },
      },
      {
        name: 'make_thing',
        http_method: 'POST',
        path: '/things',
        summary: null,
        description: null,
        effect: 'write',
        input_schema: { type: 'object', properties: {} },
      },
    ];

    const open = async () => {
      renderAuthedPage(<ApiConnectorPage />, {
        props: { project, apiConnector: buildApiConnector({ id: 3 }), operations: [], configItemNames: [] },
      });
      await userEvent.click(screen.getByRole('button', { name: 'Import operations' }));
      return screen.findByRole('dialog');
    };

    it('import preview shows warnings and imports the checked operations', async () => {
      let imported: { drafts: unknown[] } | null = null;
      answerFetch({
        [PREVIEW]: { base_url: 'https://api.example.com', drafts: DRAFTS, warnings: ['2 operations skipped'] },
        'POST /company/projects/7/api_connectors/3/api_connector_imports': (init?: RequestInit) => {
          imported = JSON.parse(String(init?.body)) as { drafts: unknown[] };
          return {};
        },
      });
      const dialog = await open();

      await userEvent.type(within(dialog).getByRole('textbox', { name: 'OpenAPI URL' }), 'https://x.test/openapi.json');
      await userEvent.click(within(dialog).getByRole('button', { name: 'Preview' }));

      expect(await within(dialog).findByText('2 operations skipped')).toBeInTheDocument();
      const list = within(dialog).getByRole('checkbox', { name: /list_things/ });
      expect(list).toBeChecked();
      await userEvent.click(within(dialog).getByRole('checkbox', { name: /make_thing/ }));

      await userEvent.click(within(dialog).getByRole('button', { name: 'Import selected (1)' }));

      await waitFor(() => expect(imported).not.toBeNull());
      expect(imported!.drafts).toEqual([DRAFTS[0]]);
    });

    it('shows the refusal next to the draft it names', async () => {
      answerFetch({
        [PREVIEW]: { base_url: 'https://api.example.com', drafts: DRAFTS, warnings: [] },
        'POST /company/projects/7/api_connectors/3/api_connector_imports': new Response(
          JSON.stringify({ errors: { '1': ['Name has already been taken'] } }),
          { status: 422, headers: { 'Content-Type': 'application/json' } },
        ),
      });
      const dialog = await open();

      await userEvent.type(within(dialog).getByRole('textbox', { name: 'OpenAPI URL' }), 'https://x.test/o.json');
      await userEvent.click(within(dialog).getByRole('button', { name: 'Preview' }));
      await userEvent.click(await within(dialog).findByRole('button', { name: 'Import selected (2)' }));

      expect(await within(dialog).findByText('Name has already been taken')).toBeInTheDocument();
    });

    it('a cURL import never shows the pasted token', async () => {
      answerFetch({
        [PREVIEW]: {
          base_url: 'https://api.example.com',
          drafts: [DRAFTS[1]],
          warnings: ['The Authorization header was not imported. Choose a Config Item for it instead.'],
        },
      });
      const dialog = await open();

      await userEvent.click(within(dialog).getByRole('tab', { name: 'cURL' }));
      await userEvent.click(within(dialog).getByRole('textbox', { name: 'cURL command' }));
      await userEvent.paste("curl -X POST https://api.example.com/things -H 'Authorization: Bearer sk-live-SECRET'");
      await userEvent.click(within(dialog).getByRole('button', { name: 'Preview' }));

      expect(await within(dialog).findByRole('checkbox', { name: /make_thing/ })).toBeInTheDocument();
      expect(screen.queryByText(/sk-live-SECRET/)).not.toBeInTheDocument();
      expect(screen.queryByDisplayValue(/sk-live-SECRET/)).not.toBeInTheDocument();
    });

    it('shows the server reason when the source cannot be read', async () => {
      answerFetch({
        [PREVIEW]: new Response(JSON.stringify({ error: 'That is not an OpenAPI document.' }), {
          status: 422,
          headers: { 'Content-Type': 'application/json' },
        }),
      });
      const dialog = await open();

      await userEvent.type(within(dialog).getByRole('textbox', { name: 'OpenAPI URL' }), 'https://x.test/o.json');
      await userEvent.click(within(dialog).getByRole('button', { name: 'Preview' }));

      expect(await within(dialog).findByText('That is not an OpenAPI document.')).toBeInTheDocument();
    });
  });

  it('offers the previewed base URL on a connector that has none yet', async () => {
    answerFetch({
      [PREVIEW]: { base_url: 'https://api.example.com', drafts: [], warnings: [] },
    });
    renderAuthedPage(<ApiConnectorPage />, {
      props: { project, apiConnector: null, operations: [], configItemNames: [] },
    });

    await userEvent.click(screen.getByRole('button', { name: 'Detect from OpenAPI or cURL' }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.type(within(dialog).getByRole('textbox', { name: 'OpenAPI URL' }), 'https://x.test/o.json');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Preview' }));
    await userEvent.click(await within(dialog).findByRole('button', { name: 'Use https://api.example.com' }));

    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    expect(screen.getByRole('textbox', { name: 'Base URL' })).toHaveValue('https://api.example.com');
  });
});
