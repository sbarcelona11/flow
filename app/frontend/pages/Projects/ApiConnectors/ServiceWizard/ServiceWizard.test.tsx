import '@testing-library/jest-dom/vitest';
import { router } from '@inertiajs/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { buildImportDraft, buildImportPreview } from 'test/factories/serviceWizard';
import { answerFetch, jsonResponse } from 'test/fetchStub';
import { renderAuthedPage, screen, userEvent, waitFor, within } from 'test/renderPage';

import { ServiceWizard } from './ServiceWizard';

const PREVIEW = 'POST /company/projects/7/api_connector_imports/preview';
const SETUP = 'POST /company/projects/7/api_service_setups';
const TEST_CALL = 'POST /company/projects/7/api_connectors/21/api_operations/31/test_call';

const created = {
  connector: { id: 21, name: 'stripe', editPath: '/company/projects/7/api_connectors/21/edit' },
  operations: [
    { id: 31, name: 'list_invoices' },
    { id: 32, name: 'create_invoice' },
    { id: 33, name: 'list_customers' },
  ],
  blocks: [{ id: 1, key: 'local/list-invoices@1', label: 'List invoices' }],
  warnings: [],
};

const drafts = [
  buildImportDraft({
    input_schema: {
      type: 'object',
      properties: { query: { type: 'object', properties: { limit: { type: 'integer' } } } },
    },
  }),
  buildImportDraft({
    name: 'create_invoice',
    http_method: 'POST',
    path: '/invoices',
    summary: 'Create an invoice',
    effect: 'write',
    tag: 'Invoices',
  }),
  buildImportDraft({ name: 'list_customers', path: '/customers', summary: 'List customers', tag: 'Customers' }),
];

const renderWizard = () =>
  renderAuthedPage(<ServiceWizard opened onClose={vi.fn()} projectId={7} configItemNames={['STRIPE_KEY', 'OTHER']} />);

async function readSpec(preview = buildImportPreview({ drafts })) {
  const fetchSpy = answerFetch({ [PREVIEW]: preview });
  await userEvent.type(
    screen.getByRole('textbox', { name: 'Link to the spec' }),
    'https://api.stripe.com/openapi.json',
  );
  await userEvent.click(screen.getByRole('button', { name: 'Read the spec' }));
  await screen.findByRole('heading', { name: 'Connection' });
  return fetchSpy;
}

async function choose(label: string, option: string) {
  await userEvent.click(screen.getByRole('combobox', { name: label }));
  await userEvent.click(await screen.findByRole('option', { name: option }));
}

async function toReview() {
  await readSpec();
  await choose('Secret', 'STRIPE_KEY');
  await userEvent.click(screen.getByRole('button', { name: 'Next' }));
  await userEvent.click(screen.getByRole('button', { name: 'Select all reads' }));
  await userEvent.click(screen.getByRole('checkbox', { name: /POST \/invoices/ }));
  await userEvent.click(screen.getByRole('button', { name: 'Next' }));
  await userEvent.click(screen.getByRole('button', { name: 'Next' }));
  await screen.findByRole('heading', { name: 'Review and create' });
}

const bodyOf = (spy: ReturnType<typeof answerFetch>, route: string) => {
  const [, path] = route.split(' ');
  const call = spy.mock.calls.find(([url]) => String(url) === path);
  return JSON.parse(String((call?.[1] as RequestInit).body)) as Record<string, unknown>;
};

describe('Projects/ApiConnectors/ServiceWizard', () => {
  beforeEach(() => {
    vi.mocked(router.reload).mockClear();
  });

  it('reads a spec and prefills the connection from the first server and the first auth suggestion', async () => {
    renderWizard();
    await readSpec();

    expect(screen.getByRole('textbox', { name: 'Base URL' })).toHaveValue('https://api.stripe.com');
    expect(screen.getByRole('textbox', { name: 'Name' })).toHaveValue('stripe');
    expect(screen.getByRole('combobox', { name: 'Authentication' })).toHaveValue('Bearer token');
    expect(screen.getByRole('heading', { name: 'Connection' })).toHaveFocus();
  });

  it('shows what the source said as plain text, never as markup', async () => {
    renderWizard();
    const tricky = '<img src=x onerror="alert(1)"> **bold** <b>x</b>';
    await readSpec(
      buildImportPreview({
        drafts: [buildImportDraft({ summary: tricky, tag: '<script>t</script>' })],
        warnings: ['<i>careful</i>'],
      }),
    );

    expect(screen.getByText('<i>careful</i>')).toBeInTheDocument();
    await choose('Secret', 'STRIPE_KEY');
    await userEvent.click(screen.getByRole('button', { name: 'Next' }));
    expect(screen.getByText('<script>t</script>')).toBeInTheDocument();
    expect(screen.getByText(tricky)).toBeInTheDocument();
    expect(screen.queryByRole('img')).not.toBeInTheDocument();
  });

  it('works with the keyboard alone: Enter reads the spec, Tab and Enter on Next move on', async () => {
    answerFetch({ [PREVIEW]: buildImportPreview({ drafts, auth_suggestions: [] }) });
    renderWizard();

    const link = screen.getByRole('textbox', { name: 'Link to the spec' });
    await waitFor(() => expect(link).toHaveFocus());
    await userEvent.keyboard('https://api.stripe.com/spec.json{Enter}');
    const connection = await screen.findByRole('heading', { name: 'Connection' });
    await waitFor(() => expect(connection).toHaveFocus());

    await userEvent.tab({ shift: false });
    expect(screen.getByRole('textbox', { name: /Name/ })).toHaveFocus();
    await userEvent.tab();
    await userEvent.tab();
    await userEvent.tab();
    await userEvent.tab();
    expect(screen.getByRole('button', { name: 'Next' })).toHaveFocus();
    await userEvent.keyboard('{Enter}');
    expect(await screen.findByRole('heading', { name: 'Choose operations' })).toHaveFocus();
  });

  it('explains what is missing in a live region instead of moving on', async () => {
    renderWizard();
    await readSpec();
    await userEvent.click(screen.getByRole('button', { name: 'Next' }));

    expect(screen.getByRole('heading', { name: 'Connection' })).toBeInTheDocument();
    expect(within(screen.getByRole('status')).getByText(/Choose the secret the service needs/)).toBeInTheDocument();
  });

  it('only offers effects at or above what the spec says', async () => {
    renderWizard();
    await readSpec();
    await choose('Secret', 'STRIPE_KEY');
    await userEvent.click(screen.getByRole('button', { name: 'Next' }));
    await userEvent.click(screen.getByRole('checkbox', { name: /POST \/invoices/ }));

    await userEvent.click(screen.getByRole('combobox', { name: 'Effect for create_invoice' }));
    expect(screen.queryByRole('option', { name: 'Read' })).not.toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Write' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Irreversible' })).toBeInTheDocument();
  });

  it('groups operations by tag and filters them with the search', async () => {
    renderWizard();
    await readSpec();
    await choose('Secret', 'STRIPE_KEY');
    await userEvent.click(screen.getByRole('button', { name: 'Next' }));

    expect(screen.getByRole('heading', { name: 'Customers' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Invoices' })).toBeInTheDocument();
    await userEvent.type(screen.getByRole('searchbox', { name: 'Search operations' }), 'customers');
    expect(screen.queryByRole('checkbox', { name: /POST \/invoices/ })).not.toBeInTheDocument();
    expect(screen.getByRole('checkbox', { name: /GET \/customers/ })).toBeInTheDocument();
  });

  it('shows which secret goes to which host and only creates after the person confirms it', async () => {
    renderWizard();
    await toReview();

    expect(screen.getByText('STRIPE_KEY is sent to api.stripe.com')).toBeInTheDocument();
    const create = screen.getByRole('button', { name: 'Create service' });
    expect(create).toBeDisabled();

    const spy = answerFetch({ [SETUP]: jsonResponse(created, 201) });
    await userEvent.click(
      screen.getByRole('checkbox', { name: 'I understand STRIPE_KEY will be sent to api.stripe.com' }),
    );
    await userEvent.click(create);

    await screen.findByRole('heading', { name: 'Try it' });
    expect(spy.mock.calls.filter(([url]) => String(url).endsWith('/api_service_setups'))).toHaveLength(1);
    expect(bodyOf(spy, SETUP)).toMatchObject({
      blocks: true,
      confirmed_secret_host: ['STRIPE_KEY → api.stripe.com'],
      connector: {
        name: 'stripe',
        base_url: 'https://api.stripe.com',
        auth_type: 'bearer',
        auth_config: { config_item_name: 'STRIPE_KEY' },
      },
      operations: [
        expect.objectContaining({ name: 'list_invoices', effect: 'read', label: 'List invoices' }),
        expect.objectContaining({ name: 'create_invoice', http_method: 'POST', effect: 'write' }),
        expect.objectContaining({ name: 'list_customers', effect: 'read' }),
      ],
    });
  });

  it('lists every operation with its effect and can skip the blocks', async () => {
    renderWizard();
    await toReview();

    const list = screen.getByRole('list', { name: 'Operations to create' });
    expect(within(list).getByText(/GET \/invoices/)).toBeInTheDocument();
    expect(within(list).getAllByText('Read').length).toBe(2);
    expect(within(list).getByText('Write')).toBeInTheDocument();

    const spy = answerFetch({ [SETUP]: jsonResponse(created, 201) });
    await userEvent.click(screen.getByRole('checkbox', { name: 'Also create a block for each operation' }));
    await userEvent.click(screen.getByRole('checkbox', { name: /I understand STRIPE_KEY/ }));
    await userEvent.click(screen.getByRole('button', { name: 'Create service' }));
    await screen.findByRole('heading', { name: 'Try it' });

    expect(bodyOf(spy, SETUP)).toMatchObject({ blocks: false });
  });

  it('sends no confirmation when the service needs no secret', async () => {
    renderWizard();
    await readSpec(buildImportPreview({ drafts, auth_suggestions: [] }));
    await userEvent.click(screen.getByRole('button', { name: 'Next' }));
    await userEvent.click(screen.getByRole('checkbox', { name: /POST \/invoices/ }));
    await userEvent.click(screen.getByRole('button', { name: 'Next' }));
    await userEvent.click(screen.getByRole('button', { name: 'Next' }));

    expect(screen.queryByRole('checkbox', { name: /I understand/ })).not.toBeInTheDocument();
    const spy = answerFetch({ [SETUP]: jsonResponse(created, 201) });
    await userEvent.click(screen.getByRole('button', { name: 'Create service' }));
    await screen.findByRole('heading', { name: 'Done' });

    expect(bodyOf(spy, SETUP)).not.toHaveProperty('confirmed_secret_host');
  });

  it('takes the person back to the connection when the server refuses it there', async () => {
    renderWizard();
    await toReview();
    answerFetch({
      [SETUP]: jsonResponse(
        {
          error: 'Config item missing',
          errors: { 'connector.auth_config': ['NOPE is not a Config Item in this project'] },
        },
        422,
      ),
    });
    await userEvent.click(screen.getByRole('checkbox', { name: /I understand STRIPE_KEY/ }));
    await userEvent.click(screen.getByRole('button', { name: 'Create service' }));

    expect(await screen.findByRole('heading', { name: 'Connection' })).toBeInTheDocument();
    expect(
      within(screen.getByRole('status')).getByText('NOPE is not a Config Item in this project'),
    ).toBeInTheDocument();
  });

  it('shows an operation error next to the operation on the operations step', async () => {
    renderWizard();
    await toReview();
    answerFetch({
      [SETUP]: jsonResponse({ error: 'x', errors: { 'operations.1': ['Name has already been taken'] } }, 422),
    });
    await userEvent.click(screen.getByRole('checkbox', { name: /I understand STRIPE_KEY/ }));
    await userEvent.click(screen.getByRole('button', { name: 'Create service' }));

    expect(await screen.findByRole('heading', { name: 'Choose operations' })).toBeInTheDocument();
    expect(screen.getByText('Name has already been taken')).toBeInTheDocument();
  });

  it('shows a mismatch of the confirmed line on the review step', async () => {
    renderWizard();
    await toReview();
    answerFetch({
      [SETUP]: jsonResponse(
        {
          error: 'x',
          errors: { 'connector.confirmed_secret_host': ['Confirm where the secret goes: STRIPE_KEY → api.stripe.com'] },
        },
        422,
      ),
    });
    await userEvent.click(screen.getByRole('checkbox', { name: /I understand STRIPE_KEY/ }));
    await userEvent.click(screen.getByRole('button', { name: 'Create service' }));

    expect(await screen.findByText('Confirm where the secret goes: STRIPE_KEY → api.stripe.com')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Review and create' })).toBeInTheDocument();
  });

  describe('Try it', () => {
    async function toTry() {
      await toReview();
      answerFetch({ [SETUP]: jsonResponse(created, 201) });
      await userEvent.click(screen.getByRole('checkbox', { name: /I understand STRIPE_KEY/ }));
      await userEvent.click(screen.getByRole('button', { name: 'Create service' }));
      await screen.findByRole('heading', { name: 'Try it' });
    }

    it('offers only read operations', async () => {
      renderWizard();
      await toTry();

      await userEvent.click(screen.getByRole('combobox', { name: 'Operation to try' }));
      expect(screen.getByRole('option', { name: 'list_invoices' })).toBeInTheDocument();
      expect(screen.queryByRole('option', { name: 'create_invoice' })).not.toBeInTheDocument();
    });

    it('sends the arguments and shows the status and the redacted preview', async () => {
      renderWizard();
      await toTry();
      const spy = answerFetch({
        [TEST_CALL]: {
          ok: true,
          status: 200,
          preview: '{"data":[{"key":"[redacted]"}]}',
          truncated: false,
          error: null,
        },
      });

      await userEvent.type(screen.getByRole('textbox', { name: /limit/ }), '5');
      await userEvent.click(screen.getByRole('button', { name: 'Send a test request' }));

      expect(await screen.findByText('Status 200')).toBeInTheDocument();
      expect(screen.getByText('{"data":[{"key":"[redacted]"}]}')).toBeInTheDocument();
      await waitFor(() => expect(bodyOf(spy, TEST_CALL)).toEqual({ arguments: { query: { limit: 5 } } }));
    });

    it('shows a refusal as a message, not as a result', async () => {
      renderWizard();
      await toTry();
      answerFetch({
        [TEST_CALL]: {
          ok: false,
          status: null,
          preview: null,
          truncated: false,
          error: 'Only read operations can be tried.',
        },
      });

      await userEvent.click(screen.getByRole('button', { name: 'Send a test request' }));

      expect(await screen.findByText('Only read operations can be tried.')).toBeInTheDocument();
      expect(screen.queryByText(/^Status/)).not.toBeInTheDocument();
    });

    it('ends on Done with links to the workflows and the new connector', async () => {
      renderWizard();
      await toTry();
      await userEvent.click(screen.getByRole('button', { name: 'Continue' }));

      expect(await screen.findByRole('heading', { name: 'Done' })).toHaveFocus();
      expect(screen.getByRole('link', { name: 'Use it in a workflow' })).toHaveAttribute(
        'href',
        '/company/projects/7/workflows',
      );
      expect(screen.getByRole('link', { name: 'Open the connector' })).toHaveAttribute(
        'href',
        '/company/projects/7/api_connectors/21/edit',
      );
    });
  });

  it('adds a secret in a modal and then offers its name, without the wizard keeping the value', async () => {
    renderWizard();
    await readSpec();
    const spy = answerFetch({ 'POST /company/projects/7/config_items': {} });

    await userEvent.click(screen.getByRole('button', { name: 'Add a secret' }));
    const dialog = await screen.findByRole('dialog', { name: 'Add secret' });
    await userEvent.type(within(dialog).getByRole('textbox', { name: /Name/ }), 'NEW_KEY');
    await userEvent.type(within(dialog).getByLabelText(/Value/), 'sk_live_abc');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Create' }));

    await waitFor(() => expect(router.reload).toHaveBeenCalledWith({ only: ['configItemNames'] }));
    expect(spy).toHaveBeenCalled();
    expect(screen.getByRole('combobox', { name: 'Secret' })).toHaveValue('NEW_KEY');
    expect(screen.queryByDisplayValue('sk_live_abc')).not.toBeInTheDocument();
  });

  it('starts from just an address', async () => {
    renderWizard();
    await userEvent.click(screen.getByRole('radio', { name: 'I only have the address' }));
    await userEvent.type(screen.getByRole('textbox', { name: 'Address' }), 'https://api.example.com');
    await userEvent.click(screen.getByRole('button', { name: 'Use this address' }));

    expect(await screen.findByRole('heading', { name: 'Connection' })).toBeInTheDocument();
    expect(screen.getByRole('textbox', { name: 'Base URL' })).toHaveValue('https://api.example.com');
  });

  it('shows the importer refusal on the source step', async () => {
    answerFetch({ [PREVIEW]: jsonResponse({ error: 'That address is not allowed.' }, 422) });
    renderWizard();
    await userEvent.type(screen.getByRole('textbox', { name: 'Link to the spec' }), 'https://x.test/spec');
    await userEvent.click(screen.getByRole('button', { name: 'Read the spec' }));

    expect(await within(screen.getByRole('status')).findByText('That address is not allowed.')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Where is the API described?' })).toBeInTheDocument();
  });
});
