import {
  ActionIcon,
  Button,
  Checkbox,
  NumberInput,
  type NumberInputProps,
  Select,
  Textarea,
  TextInput,
} from '@mantine/core';
import { IconTrash } from '@tabler/icons-react';
import { useState } from 'react';

type Json = Record<string, unknown>;

const INPUT_STYLES = {
  input: {
    background: 'transparent',
    border: '1px solid var(--border)',
    borderRadius: 4,
    color: 'var(--text-1)',
    fontSize: 13,
  },
};

type Kind = 'string' | 'number' | 'integer' | 'boolean' | 'enum' | 'object' | 'array' | 'json';

const isRecord = (value: unknown): value is Json =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

function kindOf(schema: Json): Kind {
  if (Array.isArray(schema.enum) && schema.enum.length > 0) return 'enum';
  const type = Array.isArray(schema.type) ? schema.type.find((t) => t !== 'null') : schema.type;
  if (type === 'object' && isRecord(schema.properties)) return 'object';
  if (type === 'array') return 'array';
  if (type === 'string' || type === 'number' || type === 'integer' || type === 'boolean') return type;
  return 'json';
}

const isBlank = (value: unknown) =>
  value === undefined || value === null || value === '' || (isRecord(value) && Object.keys(value).length === 0);

const describe = (schema: Json) => (typeof schema.description === 'string' ? schema.description : undefined);

interface NodeProps {
  schema: Json;
  value: unknown;
  label: string;
  required: boolean;
  readOnly: boolean;
  onChange: (value: unknown) => void;
}

function JsonField({ schema, value, label, required, readOnly, onChange }: NodeProps) {
  const [text, setText] = useState(() =>
    value === undefined ? '' : typeof value === 'string' ? value : JSON.stringify(value, null, 2),
  );
  return (
    <Textarea
      label={label}
      description={describe(schema)}
      required={required}
      disabled={readOnly}
      autosize
      minRows={2}
      value={text}
      placeholder="JSON, or {{context:key}}"
      styles={INPUT_STYLES}
      onChange={(e) => {
        const next = e.currentTarget.value;
        setText(next);
        if (next.trim() === '') return onChange(undefined);
        try {
          onChange(JSON.parse(next));
        } catch {
          onChange(next);
        }
      }}
    />
  );
}

interface NumberFieldProps extends Omit<NumberInputProps, 'value' | 'onChange'> {
  value: unknown;
  onChange: (value: unknown) => void;
}

/** Keeps what was typed ("1.") while only a finished number is emitted. */
function NumberField({ value, onChange, ...rest }: NumberFieldProps) {
  const [text, setText] = useState<string | number>(typeof value === 'number' ? value : '');
  return (
    <NumberInput
      {...rest}
      hideControls
      value={text}
      onChange={(next) => {
        setText(next);
        if (typeof next === 'number') onChange(next);
        else if (next === '') onChange(undefined);
      }}
    />
  );
}

function ValueControl({ schema, value, label, required, readOnly, onChange }: NodeProps & { kind: Kind }) {
  const kind = kindOf(schema);
  const common = { label, description: describe(schema), required, disabled: readOnly, styles: INPUT_STYLES };

  if (kind === 'string') {
    return (
      <TextInput
        {...common}
        value={typeof value === 'string' ? value : ''}
        onChange={(e) => onChange(e.currentTarget.value)}
      />
    );
  }
  if (kind === 'number' || kind === 'integer') {
    return <NumberField {...common} allowDecimal={kind === 'number'} value={value} onChange={onChange} />;
  }
  if (kind === 'boolean') {
    return (
      <Select
        {...common}
        data={['true', 'false']}
        clearable
        value={typeof value === 'boolean' ? String(value) : null}
        onChange={(next) => onChange(next === null ? undefined : next === 'true')}
      />
    );
  }
  const options = (schema.enum as unknown[]) ?? [];
  return (
    <Select
      {...common}
      data={options.map((option) => String(option))}
      clearable
      value={value === undefined || typeof value === 'string' ? ((value as string | undefined) ?? null) : String(value)}
      onChange={(next) => onChange(next === null ? undefined : (options.find((o) => String(o) === next) ?? next))}
    />
  );
}

function ObjectNode({ schema, value, label, readOnly, onChange }: NodeProps) {
  const current = isRecord(value) ? value : {};
  return (
    <fieldset aria-label={label} style={{ border: '1px solid var(--border)', borderRadius: 4, padding: 8, margin: 0 }}>
      <legend style={{ fontSize: 13 }}>{label}</legend>
      {describe(schema) && <div style={{ fontSize: 12 }}>{describe(schema)}</div>}
      <Properties
        schema={schema}
        value={current}
        readOnly={readOnly}
        onChange={(next) => onChange(isBlank(next) ? undefined : next)}
      />
    </fieldset>
  );
}

function ArrayNode({ schema, value, label, required, readOnly, onChange }: NodeProps) {
  const items = Array.isArray(value) ? value : [];
  const itemSchema = isRecord(schema.items) ? schema.items : {};
  const replace = (next: unknown[]) => onChange(next.length === 0 ? undefined : next);

  return (
    <fieldset aria-label={label} style={{ border: '1px solid var(--border)', borderRadius: 4, padding: 8, margin: 0 }}>
      <legend style={{ fontSize: 13 }}>
        {label}
        {required ? ' *' : ''}
      </legend>
      {describe(schema) && <div style={{ fontSize: 12 }}>{describe(schema)}</div>}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {items.map((item, index) => (
          // Items have no identity of their own; position is the only key an editable list of plain values has.

          <div key={index} style={{ display: 'flex', gap: 6, alignItems: 'flex-end' }}>
            <div style={{ flex: 1 }}>
              <FieldNode
                schema={itemSchema}
                value={item}
                label={`${label} ${index + 1}`}
                required={false}
                readOnly={readOnly}
                onChange={(next) => replace(items.map((old, i) => (i === index ? (next ?? null) : old)))}
              />
            </div>
            {!readOnly && (
              <ActionIcon
                variant="subtle"
                aria-label={`Remove ${label} ${index + 1}`}
                onClick={() => replace(items.filter((_, i) => i !== index))}
              >
                <IconTrash size={14} />
              </ActionIcon>
            )}
          </div>
        ))}
        {!readOnly && (
          <div>
            <Button
              size="xs"
              variant="light"
              aria-label={`Add ${label} item`}
              onClick={() => onChange([...items, kindOf(itemSchema) === 'object' ? {} : ''])}
            >
              Add item
            </Button>
          </div>
        )}
      </div>
    </fieldset>
  );
}

function FieldNode(props: NodeProps) {
  const { schema, value, label, readOnly, onChange } = props;
  const kind = kindOf(schema);
  const [armed, setArmed] = useState(false);
  const canReference = kind !== 'string' && kind !== 'json';
  const referencing = canReference && (typeof value === 'string' || armed);

  if (kind === 'json') return <JsonField {...props} />;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
      {referencing ? (
        <TextInput
          label={label}
          description={describe(schema)}
          required={props.required}
          disabled={readOnly}
          styles={INPUT_STYLES}
          placeholder="{{context:key}} or {{output:step:name}}"
          value={typeof value === 'string' ? value : ''}
          onChange={(e) => onChange(e.currentTarget.value === '' ? undefined : e.currentTarget.value)}
        />
      ) : kind === 'object' ? (
        <ObjectNode {...props} />
      ) : kind === 'array' ? (
        <ArrayNode {...props} />
      ) : (
        <ValueControl {...props} kind={kind} />
      )}
      {canReference && (
        <Checkbox
          size="xs"
          label="Use a reference"
          aria-label={`${label} use a reference`}
          disabled={readOnly}
          checked={referencing}
          onChange={(e) => {
            const on = e.currentTarget.checked;
            setArmed(on);
            onChange(undefined);
          }}
        />
      )}
    </div>
  );
}

interface PropertiesProps {
  schema: Json;
  value: Json;
  readOnly: boolean;
  onChange: (value: Json) => void;
}

function Properties({ schema, value, readOnly, onChange }: PropertiesProps) {
  const properties = isRecord(schema.properties) ? schema.properties : {};
  const required = Array.isArray(schema.required) ? schema.required : [];

  const set = (name: string, next: unknown) => {
    const rest = Object.fromEntries(Object.entries(value).filter(([key]) => key !== name));
    onChange(isBlank(next) ? rest : { ...rest, [name]: next });
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      {Object.entries(properties).map(([name, raw]) => (
        <FieldNode
          key={name}
          schema={isRecord(raw) ? raw : {}}
          value={value[name]}
          label={name}
          required={required.includes(name)}
          readOnly={readOnly}
          onChange={(next) => set(name, next)}
        />
      ))}
    </div>
  );
}

interface SchemaFormProps {
  /** A JSON Schema object: its `properties` become the fields. */
  schema: Json;
  value: Json;
  readOnly?: boolean;
  onChange: (value: Json) => void;
}

/**
 * Renders the properties of a JSON Schema object and emits the arguments object. Descriptions are
 * plain text. Any field that is not text can instead hold a `{{context:key}}` or
 * `{{output:<stepId>:<name>}}` reference, which is emitted as a string.
 */
export function SchemaForm({ schema, value, readOnly = false, onChange }: SchemaFormProps) {
  if (!isRecord(schema.properties) || Object.keys(schema.properties).length === 0) {
    return <div>This takes no settings.</div>;
  }
  return <Properties schema={schema} value={value} readOnly={readOnly} onChange={onChange} />;
}
