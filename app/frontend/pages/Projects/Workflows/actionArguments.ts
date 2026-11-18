import type { Step } from '@/types/generated';

import { outputTokens, stepKey, withDependency } from './builderDraft';

export { ACTION_EFFECTS, type ActionEffect, allowedEffects } from 'shared/lib/actionEffects';

export type FieldType = 'string' | 'number' | 'integer' | 'boolean' | 'enum' | 'json';

export interface Field {
  name: string;
  type: FieldType;
  required: boolean;
  description: string | null;
  options: string[];
}

type Values = Record<string, string>;

const SCALAR_TYPES = ['string', 'number', 'integer', 'boolean'] as const;

function fieldType(property: Record<string, unknown>): FieldType {
  const type = property.type;
  if (Array.isArray(property.enum) && property.enum.every((option) => typeof option === 'string')) return 'enum';
  return SCALAR_TYPES.find((scalar) => scalar === type) ?? 'json';
}

export function fieldsFor(inputSchema: Record<string, unknown>): Field[] {
  const properties = inputSchema.properties;
  if (typeof properties !== 'object' || properties === null) return [];
  const required = Array.isArray(inputSchema.required) ? inputSchema.required : [];

  return Object.entries(properties).map(([name, raw]) => {
    const property = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {};
    const type = fieldType(property);
    return {
      name,
      type,
      required: required.includes(name),
      description: typeof property.description === 'string' ? property.description : null,
      options: type === 'enum' ? (property.enum as string[]) : [],
    };
  });
}

function parsed(field: Field, value: string): unknown {
  const text = value.trim();
  if (field.type === 'number' || field.type === 'integer') {
    const number = Number(text);
    return Number.isFinite(number) ? number : value;
  }
  if (field.type === 'boolean') return text === 'true' ? true : text === 'false' ? false : value;
  if (field.type === 'json') {
    try {
      return JSON.parse(text);
    } catch {
      return value;
    }
  }
  return value;
}

export function toArguments(values: Values, fields: Field[]): Record<string, unknown> {
  const args: Record<string, unknown> = {};
  for (const field of fields) {
    const value = values[field.name];
    if (value === undefined || value.trim() === '') continue;
    args[field.name] = parsed(field, value);
  }
  return args;
}

export function fromArguments(args: Record<string, unknown>, fields: Field[]): Values {
  const values: Values = {};
  for (const field of fields) {
    const value = args[field.name];
    if (value === undefined || value === null) continue;
    values[field.name] =
      typeof value === 'string' ? value : field.type === 'json' ? JSON.stringify(value, null, 2) : String(value);
  }
  return values;
}

/** The server rejects an action with more output tokens than this (`Actions::Arguments`). */
export const MAX_OUTPUT_TOKENS = 20;

export interface PortBinding {
  from: number;
  port: string;
  to: number;
  argument: string;
}

const outputTokenCount = (args: Record<string, unknown>, except: string) =>
  Object.entries(args).reduce(
    (count, [name, value]) => (name === except ? count : count + outputTokens(value).length),
    0,
  );

/**
 * The steps with `argument` of `to` fed by `from`'s `port`, and `to` running after `from`; `null` when the
 * dependency is refused, the target is a Wrapper (it cannot read outputs) or the action is out of tokens.
 * Port types are not compared: the server's data-flow check does that.
 */
export function withPortBinding(steps: Step[], { from, port, to, argument }: PortBinding): Step[] | null {
  const target = steps.find((s) => s.id === to);
  if (!target || target.kindConfig.target === 'wrapper') return null;
  const args = target.kindConfig.arguments ?? {};
  if (outputTokenCount(args, argument) >= MAX_OUTPUT_TOKENS) return null;
  const ordered = target.dependsOnStepIds.includes(from) ? steps : withDependency(steps, to, from);
  if (!ordered || from === to) return null;
  const token = `{{output:${stepKey(from)}:${port}.json}}`;
  return ordered.map((s) =>
    s.id === to ? { ...s, kindConfig: { ...s.kindConfig, arguments: { ...args, [argument]: token } } } : s,
  );
}

/** The steps with `argument` of `stepId` cleared; the dependency stays, it may serve other arguments or be wanted anyway. */
export function withoutPortBinding(steps: Step[], stepId: number, argument: string): Step[] {
  return steps.map((s) => {
    if (s.id !== stepId || !s.kindConfig.arguments || !(argument in s.kindConfig.arguments)) return s;
    const rest = Object.fromEntries(Object.entries(s.kindConfig.arguments).filter(([name]) => name !== argument));
    return { ...s, kindConfig: { ...s.kindConfig, arguments: rest } };
  });
}
