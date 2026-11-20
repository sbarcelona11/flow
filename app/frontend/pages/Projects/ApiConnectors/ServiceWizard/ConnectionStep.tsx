import { Alert, Button, Group, Select, Stack, Text, TextInput } from '@mantine/core';
import type { Ref } from 'react';

import { AUTH_LABELS } from '../apiConnectorLabels';

import { StepHeading } from './StepHeading';
import { type AuthType, type Connection, type SecretField, STEP_TITLES } from './wizardState';

const AUTH_TYPES = Object.keys(AUTH_LABELS) as AuthType[];

interface ConnectionStepProps {
  headingRef: Ref<HTMLHeadingElement>;
  connection: Connection;
  servers: string[];
  warnings: string[];
  secretNames: string[];
  onChange: (patch: Partial<Connection>) => void;
  onAddSecret: (field: SecretField) => void;
}

export function ConnectionStep({
  headingRef,
  connection,
  servers,
  warnings,
  secretNames,
  onChange,
  onAddSecret,
}: ConnectionStepProps) {
  const secretSelect = (field: SecretField, label: string) => (
    <Group gap="xs" align="flex-end" wrap="nowrap">
      <Select
        label={label}
        placeholder="Choose a secret"
        data={secretNames}
        value={connection[field] || null}
        onChange={(value) => onChange({ [field]: value ?? '' })}
        searchable
        style={{ flex: 1 }}
      />
      <Button variant="light" onClick={() => onAddSecret(field)}>
        Add a secret
      </Button>
    </Group>
  );

  return (
    <Stack gap="md">
      <StepHeading title={STEP_TITLES.connection} headingRef={headingRef} />
      {warnings.length > 0 && (
        <Alert color="yellow" variant="light" title="Worth a look">
          <Stack gap={2}>
            {warnings.map((warning) => (
              <Text key={warning} fz={13}>
                {warning}
              </Text>
            ))}
          </Stack>
        </Alert>
      )}
      <TextInput
        label="Name"
        value={connection.name}
        onChange={(e) => onChange({ name: e.currentTarget.value })}
        required
      />
      {servers.length > 1 && (
        <Select
          label="Servers in the spec"
          data={servers}
          value={servers.includes(connection.baseUrl) ? connection.baseUrl : null}
          onChange={(value) => value && onChange({ baseUrl: value })}
          allowDeselect={false}
        />
      )}
      <TextInput
        label="Base URL"
        description="https only. Every call goes to this host and nowhere else."
        value={connection.baseUrl}
        onChange={(e) => onChange({ baseUrl: e.currentTarget.value })}
        required
      />
      <Select
        label="Authentication"
        data={AUTH_TYPES.map((value) => ({ value, label: AUTH_LABELS[value] }))}
        value={connection.authType}
        onChange={(value) => value && onChange({ authType: value as AuthType })}
        allowDeselect={false}
      />
      {(connection.authType === 'bearer' ||
        connection.authType === 'api_key_header' ||
        connection.authType === 'api_key_query') &&
        secretSelect('configItem', 'Secret')}
      {connection.authType === 'api_key_header' && (
        <TextInput
          label="Header name"
          placeholder="X-Api-Key"
          value={connection.headerName}
          onChange={(e) => onChange({ headerName: e.currentTarget.value })}
        />
      )}
      {connection.authType === 'api_key_query' && (
        <TextInput
          label="Query parameter"
          placeholder="api_key"
          value={connection.queryParam}
          onChange={(e) => onChange({ queryParam: e.currentTarget.value })}
        />
      )}
      {connection.authType === 'basic' && (
        <>
          {secretSelect('usernameItem', 'Username secret')}
          {secretSelect('passwordItem', 'Password secret')}
        </>
      )}
      {connection.authType !== 'none' && (
        <Text fz={12} c="dimmed">
          The secret itself stays in Secrets & Variables. This wizard only picks its name.
        </Text>
      )}
    </Stack>
  );
}
