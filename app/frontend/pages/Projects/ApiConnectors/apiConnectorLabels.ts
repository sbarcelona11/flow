import type { ApiConnector } from '@/types/generated';

export const AUTH_LABELS: Record<ApiConnector['authType'], string> = {
  none: 'No authentication',
  bearer: 'Bearer token',
  api_key_header: 'API key in a header',
  api_key_query: 'API key in the query string',
  basic: 'Basic (username and password)',
};
