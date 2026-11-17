import type { ApiConnector, ApiOperation } from '@/types/generated';

export const buildApiConnector = (overrides: Partial<ApiConnector> = {}): ApiConnector => ({
  id: 3,
  name: 'billing',
  baseUrl: 'https://api.example.com',
  description: null,
  enabled: true,
  archivedAt: null,
  authType: 'none',
  authConfig: {},
  defaultHeaders: {},
  operationsCount: 0,
  ...overrides,
});

export const buildApiOperation = (overrides: Partial<ApiOperation> = {}): ApiOperation => ({
  id: 11,
  name: 'list_invoices',
  method: 'GET',
  path: '/invoices',
  summary: null,
  description: null,
  effect: 'read',
  minimumEffect: 'read',
  enabled: true,
  inputSchema: {},
  ...overrides,
});
