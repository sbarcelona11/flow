import { ApiError } from 'shared/lib/apiFetch';

export const CHANGED_WHILE_OPEN =
  'This changed while you were looking at it. The latest version is shown below; look it over again before approving.';

/** The reviewer's answer for a refusal: 409 means the content moved on after it was shown. */
export const isContentChanged = (error: unknown) => error instanceof ApiError && error.status === 409;

const LOOKALIKE_ARROWS = /[\u2190-\u21ff\u2794-\u27be\u27f0-\u27ff\u2900-\u297f\u2b00-\u2bff]|-{1,2}>|={1,2}>/g;
const UNSEEN = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu;

/**
 * Text written by a spec, a manifest or an agent, made safe to show beside lines the server vouches for: one line, no
 * control or direction-changing characters, no arrow look-alikes (so it cannot pose as "ITEM → host"), and capped.
 */
export function plainLine(text: string | null | undefined, max = 200): string {
  const line = (text ?? '')
    .replace(/[\r\n\t]+/g, ' ')
    .replace(UNSEEN, '')
    .replace(LOOKALIKE_ARROWS, '-')
    .replace(/\s+/g, ' ')
    .trim();
  return line.length > max ? `${line.slice(0, max - 1)}…` : line;
}

export const proposedBy = (origin: string, sessionId: number | null, creator: string | null) => {
  const who = creator ? ` (${plainLine(creator, 80)})` : '';
  if (origin === 'builder') return `Proposed by Aixle Builder${sessionId ? ` in session #${sessionId}` : ''}${who}`;
  if (origin === 'mcp') return `Proposed through a personal token${who}`;
  return `Created on the web${who}`;
};

const asObject = (value: unknown): Record<string, unknown> =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : {};

/** One line per argument an operation takes ("query.limit: integer, required"), read from its input schema. */
export function schemaSummary(schema: unknown, limit = 30): string[] {
  const lines: string[] = [];
  const groups = asObject(asObject(schema).properties);
  for (const [group, groupSchema] of Object.entries(groups)) {
    const required = new Set(
      Array.isArray(asObject(groupSchema).required) ? (asObject(groupSchema).required as unknown[]) : [],
    );
    for (const [name, leaf] of Object.entries(asObject(asObject(groupSchema).properties))) {
      const type = asObject(leaf).type;
      const kind = typeof type === 'string' ? type : 'any';
      lines.push(plainLine(`${group}.${name}: ${kind}${required.has(name) ? ', required' : ''}`, 120));
      if (lines.length >= limit) return lines;
    }
  }
  return lines;
}
