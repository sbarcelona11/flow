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
