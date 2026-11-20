import type { ImportDraft, ImportPreview } from 'pages/Projects/ApiConnectors/ServiceWizard/wizardState';

export const buildImportDraft = (overrides: Partial<ImportDraft> = {}): ImportDraft => ({
  name: 'list_invoices',
  http_method: 'GET',
  path: '/invoices',
  summary: 'List invoices',
  description: null,
  effect: 'read',
  input_schema: {},
  tag: 'Invoices',
  response_hint: 'json',
  ...overrides,
});

export const buildImportPreview = (overrides: Partial<ImportPreview> = {}): ImportPreview => ({
  base_url: 'https://api.stripe.com',
  drafts: [buildImportDraft()],
  warnings: [],
  servers: ['https://api.stripe.com'],
  auth_suggestions: [{ auth_type: 'bearer', header_name: null, query_param: null }],
  ...overrides,
});
