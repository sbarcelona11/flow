import { router } from '@inertiajs/react';
import { ActionIcon, Alert, Button, Group, Select, Stack, Switch, Text, Textarea, TextInput } from '@mantine/core';
import { IconPlus, IconTrash } from '@tabler/icons-react';
import { useState } from 'react';

import type { ApiConnector } from '@/types/generated';

import { companyProjectApiConnectorPath, companyProjectApiConnectorsPath } from 'shared/routes';

import { AUTH_LABELS } from './apiConnectorLabels';

type AuthType = ApiConnector['authType'];

const AUTH_TYPES = Object.keys(AUTH_LABELS) as AuthType[];

const ERROR_FIELDS: Record<string, string> = {
  name: 'name',
  base_url: 'baseUrl',
  auth_config: 'authConfig',
  default_headers: 'defaultHeaders',
  description: 'description',
};

interface Header {
  key: string;
  value: string;
}

interface ConnectorFormProps {
  projectId: number;
  connector: ApiConnector | null;
  configItemNames: string[];
  baseUrl: string;
  onBaseUrlChange: (value: string) => void;
  readOnly: boolean;
}

export function ConnectorForm({
  projectId,
  connector,
  configItemNames,
  baseUrl,
  onBaseUrlChange,
  readOnly,
}: ConnectorFormProps) {
  const [name, setName] = useState(connector?.name ?? '');
  const [authType, setAuthType] = useState<AuthType>(connector?.authType ?? 'none');
  const [authConfig, setAuthConfig] = useState<Record<string, string>>(connector?.authConfig ?? {});
  const [headers, setHeaders] = useState<Header[]>(
    Object.entries(connector?.defaultHeaders ?? {}).map(([key, value]) => ({ key, value })),
  );
  const [description, setDescription] = useState(connector?.description ?? '');
  const [enabled, setEnabled] = useState(connector?.enabled ?? true);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [other, setOther] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);

  const setConfig = (key: string, value: string | null) =>
    setAuthConfig((current) => ({ ...current, [key]: value ?? '' }));

  const itemSelect = (key: string, label: string) => (
    <Select
      key={key}
      label={label}
      placeholder="Choose a Config Item"
      data={configItemNames}
      value={authConfig[key] || null}
      onChange={(value) => setConfig(key, value)}
      disabled={readOnly}
      searchable
    />
  );

  const submit = () => {
    const fields: Record<AuthType, string[]> = {
      none: [],
      bearer: ['config_item_name'],
      api_key_header: ['config_item_name', 'header_name'],
      api_key_query: ['config_item_name', 'query_param'],
      basic: ['username_item', 'password_item'],
    };
    const payload = {
      apiConnector: {
        name,
        baseUrl,
        authType,
        authConfig: Object.fromEntries(fields[authType].map((key) => [key, authConfig[key] ?? ''])),
        defaultHeaders: Object.fromEntries(headers.filter((h) => h.key.trim()).map((h) => [h.key.trim(), h.value])),
        description,
        enabled,
      },
    };
    setSaving(true);
    setErrors({});
    setOther([]);
    const options = {
      preserveScroll: true,
      onFinish: () => setSaving(false),
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
    if (connector) router.patch(companyProjectApiConnectorPath(projectId, connector.id), payload, options);
    else router.post(companyProjectApiConnectorsPath(projectId), payload, options);
  };

  const updateHeader = (index: number, field: keyof Header, value: string) =>
    setHeaders((current) => current.map((h, i) => (i === index ? { ...h, [field]: value } : h)));

  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        submit();
      }}
    >
      <Stack gap="md" maw={560}>
        {other.length > 0 && (
          <Alert color="red" variant="light">
            {other.join('\n')}
          </Alert>
        )}
        <TextInput
          label="Name"
          value={name}
          onChange={(e) => setName(e.currentTarget.value)}
          error={errors.name}
          disabled={readOnly}
          required
        />
        <TextInput
          label="Base URL"
          description="https only. Every call goes to this host and nowhere else."
          placeholder="https://api.example.com"
          value={baseUrl}
          onChange={(e) => onBaseUrlChange(e.currentTarget.value)}
          error={errors.baseUrl}
          disabled={readOnly}
          required
        />
        <Select
          label="Authentication"
          data={AUTH_TYPES.map((value) => ({ value, label: AUTH_LABELS[value] }))}
          value={authType}
          onChange={(value) => value && setAuthType(value as AuthType)}
          error={errors.authConfig}
          allowDeselect={false}
          disabled={readOnly}
        />
        {authType === 'bearer' && itemSelect('config_item_name', 'Config Item')}
        {authType === 'api_key_header' && (
          <>
            {itemSelect('config_item_name', 'Config Item')}
            <TextInput
              label="Header name"
              placeholder="X-Api-Key"
              value={authConfig.header_name ?? ''}
              onChange={(e) => setConfig('header_name', e.currentTarget.value)}
              disabled={readOnly}
            />
          </>
        )}
        {authType === 'api_key_query' && (
          <>
            {itemSelect('config_item_name', 'Config Item')}
            <TextInput
              label="Query parameter"
              placeholder="api_key"
              value={authConfig.query_param ?? ''}
              onChange={(e) => setConfig('query_param', e.currentTarget.value)}
              disabled={readOnly}
            />
          </>
        )}
        {authType === 'basic' && (
          <>
            {itemSelect('username_item', 'Username Config Item')}
            {itemSelect('password_item', 'Password Config Item')}
          </>
        )}
        {authType !== 'none' && (
          <Text fz={12} c="dimmed">
            The secret stays in the Config Item. Only its name is saved here.
          </Text>
        )}

        <Stack gap={6}>
          <Text fz={14} fw={500}>
            Default headers
          </Text>
          <Text fz={12} c="dimmed">
            Sent with every call. Not for secrets: use the authentication above.
          </Text>
          {errors.defaultHeaders && (
            <Text fz={12} c="red">
              {errors.defaultHeaders}
            </Text>
          )}
          {headers.map((header, index) => (
            <Group key={index} gap="xs" wrap="nowrap">
              <TextInput
                aria-label={`Header ${index + 1} name`}
                placeholder="Accept"
                value={header.key}
                onChange={(e) => updateHeader(index, 'key', e.currentTarget.value)}
                disabled={readOnly}
                style={{ flex: 1 }}
              />
              <TextInput
                aria-label={`Header ${index + 1} value`}
                placeholder="application/json"
                value={header.value}
                onChange={(e) => updateHeader(index, 'value', e.currentTarget.value)}
                disabled={readOnly}
                style={{ flex: 1 }}
              />
              <ActionIcon
                variant="subtle"
                color="red"
                aria-label={`Remove header ${index + 1}`}
                disabled={readOnly}
                onClick={() => setHeaders((current) => current.filter((_, i) => i !== index))}
              >
                <IconTrash size={16} />
              </ActionIcon>
            </Group>
          ))}
          <Group>
            <Button
              size="compact-sm"
              variant="subtle"
              leftSection={<IconPlus size={14} />}
              disabled={readOnly}
              onClick={() => setHeaders((current) => [...current, { key: '', value: '' }])}
            >
              Add header
            </Button>
          </Group>
        </Stack>

        <Textarea
          label="Description"
          autosize
          minRows={2}
          value={description}
          onChange={(e) => setDescription(e.currentTarget.value)}
          error={errors.description}
          disabled={readOnly}
        />
        <Switch
          label="Enabled"
          checked={enabled}
          onChange={(e) => setEnabled(e.currentTarget.checked)}
          disabled={readOnly}
        />
        {!readOnly && (
          <Group>
            <Button type="submit" loading={saving}>
              {connector ? 'Save changes' : 'Create connector'}
            </Button>
          </Group>
        )}
      </Stack>
    </form>
  );
}
