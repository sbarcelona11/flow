import type { FormDataConvertible } from '@inertiajs/core';
import { router } from '@inertiajs/react';
import { Alert, Button, Drawer, Group, Select, Stack, Switch, Text, Textarea, TextInput } from '@mantine/core';
import { useEffect, useState } from 'react';

import type { ApiOperation } from '@/types/generated';

import {
  ACTION_EFFECTS,
  type ActionEffect,
  allowedEffects,
  EFFECT_LABELS,
  EFFECT_TEXTS,
} from 'shared/lib/actionEffects';
import { companyProjectApiConnectorApiOperationPath, companyProjectApiConnectorApiOperationsPath } from 'shared/routes';

type Method = ApiOperation['method'];

const METHODS: Method[] = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];

const EMPTY_GROUPS = JSON.stringify(
  {
    type: 'object',
    properties: {
      path: { type: 'object', properties: {} },
      query: { type: 'object', properties: {} },
      body: { type: 'object', properties: {} },
    },
  },
  null,
  2,
);

const ERROR_FIELDS: Record<string, string> = {
  name: 'name',
  method: 'method',
  path: 'path',
  summary: 'summary',
  description: 'description',
  effect: 'effect',
  input_schema: 'inputSchema',
};

const minimumEffect = (method: Method): ActionEffect => (method === 'GET' ? 'read' : 'write');

const schemaText = (schema: Record<string, unknown>) =>
  Object.keys(schema).length === 0 ? EMPTY_GROUPS : JSON.stringify(schema, null, 2);

function parseSchema(text: string): { value: Record<string, FormDataConvertible> } | { error: string } {
  try {
    const value: unknown = JSON.parse(text);
    if (typeof value !== 'object' || value === null || Array.isArray(value)) {
      return { error: 'Parameters are not valid JSON: expected an object.' };
    }
    return { value: value as Record<string, FormDataConvertible> };
  } catch (error) {
    return { error: `Parameters are not valid JSON: ${error instanceof Error ? error.message : 'could not parse'}` };
  }
}

interface OperationEditorProps {
  opened: boolean;
  onClose: () => void;
  projectId: number;
  connectorId: number;
  operation: ApiOperation | null;
}

export function OperationEditor({ opened, onClose, projectId, connectorId, operation }: OperationEditorProps) {
  const [name, setName] = useState('');
  const [method, setMethod] = useState<Method>('GET');
  const [path, setPath] = useState('');
  const [summary, setSummary] = useState('');
  const [description, setDescription] = useState('');
  const [effect, setEffect] = useState<ActionEffect>('read');
  const [enabled, setEnabled] = useState(true);
  const [schema, setSchema] = useState(EMPTY_GROUPS);
  const [schemaError, setSchemaError] = useState<string | null>(null);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [other, setOther] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!opened) return;
    setName(operation?.name ?? '');
    setMethod(operation?.method ?? 'GET');
    setPath(operation?.path ?? '');
    setSummary(operation?.summary ?? '');
    setDescription(operation?.description ?? '');
    setEffect((operation?.effect as ActionEffect | undefined) ?? 'read');
    setEnabled(operation?.enabled ?? true);
    setSchema(operation ? schemaText(operation.inputSchema) : EMPTY_GROUPS);
    setSchemaError(null);
    setErrors({});
    setOther([]);
  }, [opened, operation]);

  const effects = allowedEffects(minimumEffect(method));

  const chooseMethod = (value: string | null) => {
    if (!value) return;
    const next = value as Method;
    setMethod(next);
    if (!allowedEffects(minimumEffect(next)).includes(effect)) setEffect(minimumEffect(next));
  };

  const submit = () => {
    const parsed = parseSchema(schema);
    if ('error' in parsed) {
      setSchemaError(parsed.error);
      return;
    }
    setSchemaError(null);
    setErrors({});
    setOther([]);
    setSaving(true);

    const payload = {
      apiOperation: { name, method, path, summary, description, effect, enabled, inputSchema: parsed.value },
    };
    const options = {
      preserveScroll: true,
      onFinish: () => setSaving(false),
      onSuccess: () => onClose(),
      onError: (raw: Record<string, string | string[]>) => {
        const fieldErrors: Record<string, string> = {};
        const unplaced: string[] = [];
        Object.entries(raw).forEach(([key, value]) => {
          const text = Array.isArray(value) ? value.join('; ') : value;
          if (ERROR_FIELDS[key]) fieldErrors[ERROR_FIELDS[key]] = text;
          else unplaced.push(text);
        });
        setErrors(fieldErrors);
        setOther(unplaced);
      },
    };
    if (operation) {
      router.patch(companyProjectApiConnectorApiOperationPath(projectId, connectorId, operation.id), payload, options);
    } else {
      router.post(companyProjectApiConnectorApiOperationsPath(projectId, connectorId), payload, options);
    }
  };

  return (
    <Drawer
      opened={opened}
      onClose={onClose}
      title={operation ? 'Edit operation' : 'Add operation'}
      position="right"
      size={520}
    >
      <form
        onSubmit={(event) => {
          event.preventDefault();
          submit();
        }}
      >
        <Stack gap="md">
          {other.length > 0 && (
            <Alert color="red" variant="light">
              {other.join('\n')}
            </Alert>
          )}
          <TextInput
            label="Name"
            description="What an action step calls it, such as list_invoices."
            value={name}
            onChange={(e) => setName(e.currentTarget.value)}
            error={errors.name}
            required
          />
          <Group gap="sm" align="flex-start" wrap="nowrap">
            <Select
              label="Method"
              data={METHODS}
              value={method}
              onChange={chooseMethod}
              error={errors.method}
              allowDeselect={false}
              w={130}
            />
            <TextInput
              label="Path"
              description="Use {name} for a value taken from the path arguments."
              placeholder="/invoices/{id}"
              value={path}
              onChange={(e) => setPath(e.currentTarget.value)}
              error={errors.path}
              required
              style={{ flex: 1 }}
            />
          </Group>
          <TextInput
            label="Summary"
            value={summary}
            onChange={(e) => setSummary(e.currentTarget.value)}
            error={errors.summary}
          />
          <Textarea
            label="Description"
            autosize
            minRows={2}
            value={description}
            onChange={(e) => setDescription(e.currentTarget.value)}
            error={errors.description}
          />
          <div>
            <Select
              label="Effect"
              data={ACTION_EFFECTS.filter((value) => effects.includes(value)).map((value) => ({
                value,
                label: EFFECT_LABELS[value],
              }))}
              value={effect}
              onChange={(value) => value && setEffect(value as ActionEffect)}
              error={errors.effect}
              allowDeselect={false}
            />
            <Text fz={12} c="dimmed" mt={4}>
              {EFFECT_TEXTS[effect]}
            </Text>
          </div>
          <Textarea
            label="Parameters"
            description="A JSON schema grouping the arguments as path, query and body."
            value={schema}
            onChange={(e) => setSchema(e.currentTarget.value)}
            error={schemaError ?? errors.inputSchema}
            autosize
            minRows={8}
            maxRows={20}
            spellCheck={false}
            styles={{ input: { fontFamily: 'var(--mantine-font-family-monospace)', fontSize: 12 } }}
          />
          <Switch label="Enabled" checked={enabled} onChange={(e) => setEnabled(e.currentTarget.checked)} />
          <Group justify="flex-end">
            <Button variant="default" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" loading={saving}>
              {operation ? 'Save operation' : 'Add operation'}
            </Button>
          </Group>
        </Stack>
      </form>
    </Drawer>
  );
}
