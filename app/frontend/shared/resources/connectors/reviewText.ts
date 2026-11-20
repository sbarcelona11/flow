import { ApiError } from 'shared/lib/apiFetch';

export const CHANGED_WHILE_OPEN =
  'This changed while you were looking at it. The latest version is shown below; look it over again before approving.';

/** The reviewer's answer for a refusal: 409 means the content moved on after it was shown. */
export const isContentChanged = (error: unknown) => error instanceof ApiError && error.status === 409;

export const proposedBy = (origin: string, sessionId: number | null, creator: string | null) => {
  const who = creator ? ` (${creator})` : '';
  if (origin === 'builder') return `Proposed by Aixle Builder${sessionId ? ` in session #${sessionId}` : ''}${who}`;
  if (origin === 'mcp') return `Proposed through a personal token${who}`;
  return `Created on the web${who}`;
};
