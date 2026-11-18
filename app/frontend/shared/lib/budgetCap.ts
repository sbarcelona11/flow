/** Whole US cents the server accepts for a cap (`Budgets::MAX_CENTS`). */
export const MIN_CAP_CENTS = 1;
export const MAX_CAP_CENTS = 1_000_000;

/**
 * Cents for what a dollar input holds: `null` when empty (no cap), `undefined` when it is not a
 * usable amount yet (partial text, out of range), so the caller keeps the last good value.
 * `Math.round` absorbs float drift: 1.15 * 100 is 114.99999999999999.
 */
export function capCentsFromInput(value: number | string): number | null | undefined {
  if (value === '') return null;
  if (typeof value !== 'number' || !Number.isFinite(value)) return undefined;
  const cents = Math.round(value * 100);
  return cents >= MIN_CAP_CENTS && cents <= MAX_CAP_CENTS ? cents : undefined;
}

/** What Save may send: integer cents in range, or `null`, never NaN or a string. */
export function sanitizeCapCents(value: number | null | undefined): number | null {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null;
  const cents = Math.round(value);
  return cents >= MIN_CAP_CENTS && cents <= MAX_CAP_CENTS ? cents : null;
}

/** `$x.yy` from integer cents, exact (formatCostCents abbreviates from $1000). */
export function formatCapCents(cents: number): string {
  const whole = Math.floor(cents / 100);
  const rest = String(cents % 100).padStart(2, '0');
  return `$${whole}.${rest}`;
}
