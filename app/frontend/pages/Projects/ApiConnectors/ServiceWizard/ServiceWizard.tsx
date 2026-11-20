import { router } from '@inertiajs/react';
import { Button, Group, Modal, Stack, Text } from '@mantine/core';
import { useEffect, useReducer, useRef, useState } from 'react';

import { ApiError, apiFetch, apiRequest } from 'shared/lib/apiFetch';
import { ConfigItemFormModal, type ConfigItemFormValues } from 'shared/resources/config-items/ConfigItemFormModal';
import {
  companyProjectApiServiceSetupsPath,
  companyProjectConfigItemsPath,
  previewCompanyProjectApiConnectorImportsPath,
} from 'shared/routes';

import { ConnectionStep } from './ConnectionStep';
import { DoneStep } from './DoneStep';
import { NamesStep } from './NamesStep';
import { OperationsStep } from './OperationsStep';
import { ReviewStep } from './ReviewStep';
import { SourceStep } from './SourceStep';
import { TryStep } from './TryStep';
import {
  type CreatedService,
  type ImportPreview,
  initialWizardState,
  placeSetupErrors,
  readOperationIndexes,
  secretHostLines,
  type SecretField,
  secretsConfirmed,
  selectedIndexes,
  STEP_ORDER,
  STEP_SHORT_TITLES,
  type StepId,
  wizardReducer,
  type WizardState,
} from './wizardState';

const JSON_HEADERS = { 'Content-Type': 'application/json' };

const AUTH_CONFIG_KEYS = {
  none: () => ({}),
  bearer: (c: WizardState['connection']) => ({ config_item_name: c.configItem }),
  api_key_header: (c: WizardState['connection']) => ({
    config_item_name: c.configItem,
    header_name: c.headerName.trim(),
  }),
  api_key_query: (c: WizardState['connection']) => ({
    config_item_name: c.configItem,
    query_param: c.queryParam.trim(),
  }),
  basic: (c: WizardState['connection']) => ({ username_item: c.usernameItem, password_item: c.passwordItem }),
};

function setupPayload(state: WizardState) {
  const { connection, drafts, choices } = state;
  const lines = secretHostLines(connection);
  return {
    connector: {
      name: connection.name.trim(),
      base_url: connection.baseUrl.trim(),
      auth_type: connection.authType,
      auth_config: AUTH_CONFIG_KEYS[connection.authType](connection),
      enabled: true,
    },
    operations: selectedIndexes(state).map((index) => ({
      name: drafts[index].name,
      http_method: drafts[index].http_method,
      path: drafts[index].path,
      summary: drafts[index].summary,
      description: choices[index].description,
      label: choices[index].label.trim(),
      effect: choices[index].effect,
      input_schema: drafts[index].input_schema,
      enabled: true,
    })),
    blocks: state.createBlocks,
    ...(lines.length > 0 ? { confirmed_secret_host: lines } : {}),
  };
}

interface ServiceWizardProps {
  opened: boolean;
  onClose: () => void;
  projectId: number;
  /** Names of the project's Config Items. Never values. */
  configItemNames: string[];
  onCreated?: () => void;
}

export function ServiceWizard({ opened, onClose, projectId, configItemNames, onCreated }: ServiceWizardProps) {
  const [state, dispatch] = useReducer(wizardReducer, undefined, initialWizardState);
  const [sourceError, setSourceError] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [addedNames, setAddedNames] = useState<string[]>([]);
  const [secretFor, setSecretFor] = useState<SecretField | null>(null);
  const headingRef = useRef<HTMLHeadingElement>(null);
  const arrived = useRef(false);

  useEffect(() => {
    if (!arrived.current) {
      arrived.current = true;
      return;
    }
    headingRef.current?.focus();
  }, [state.step]);

  const secretNames = [...new Set([...configItemNames, ...addedNames])].sort();

  const readPreview = (source: 'openapi_url' | 'openapi_text' | 'curl', value: string) =>
    apiRequest<ImportPreview>(previewCompanyProjectApiConnectorImportsPath(projectId), {
      method: 'POST',
      headers: JSON_HEADERS,
      body: JSON.stringify({ source, value: source === 'openapi_url' ? value.trim() : value }),
    });

  const create = async () => {
    setCreating(true);
    try {
      const service = await apiRequest<CreatedService>(companyProjectApiServiceSetupsPath(projectId), {
        method: 'POST',
        headers: JSON_HEADERS,
        body: JSON.stringify(setupPayload(state)),
      });
      dispatch({ type: 'created', service });
      onCreated?.();
    } catch (failure) {
      const body = failure instanceof ApiError ? (failure.body as { errors?: Record<string, string[]> } | null) : null;
      const message = failure instanceof Error ? failure.message : 'The service could not be created.';
      const placed = placeSetupErrors(state, body && typeof body === 'object' ? (body.errors ?? {}) : {}, message);
      dispatch({ type: 'failed', ...placed });
    } finally {
      setCreating(false);
    }
  };

  // The form holds the value for as long as it is open; only the name comes back here.
  const saveSecret = async (values: ConfigItemFormValues) => {
    try {
      const res = await apiFetch(companyProjectConfigItemsPath(projectId), {
        method: 'POST',
        headers: JSON_HEADERS,
        redirect: 'manual',
        body: JSON.stringify({ configItem: values }),
      });
      if (!res.ok && res.type !== 'opaqueredirect') return false;
    } catch {
      return false;
    }
    setAddedNames((names) => [...names, values.name]);
    if (secretFor) dispatch({ type: 'setConnection', patch: { [secretFor]: values.name } });
    router.reload({ only: ['configItemNames'] });
    return true;
  };

  const { step, errors } = state;
  const liveMessages = [
    ...(sourceError && step === 'source' ? [sourceError] : []),
    ...errors.step,
    ...(step === 'connection' ? errors.connector : []),
    ...(step === 'review' ? errors.review : []),
  ];

  const tryOperations = state.created
    ? readOperationIndexes(state).flatMap((index) => {
        const made = state.created?.operations.find((operation) => operation.name === state.drafts[index].name);
        return made ? [{ id: made.id, name: made.name, inputSchema: state.drafts[index].input_schema }] : [];
      })
    : [];

  const confirmed = secretsConfirmed(state);
  const lines = secretHostLines(state.connection);

  return (
    <>
      <Modal opened={opened} onClose={onClose} title="Add a REST service" size="xl" closeOnClickOutside={false}>
        <Stack gap="lg">
          <ol
            aria-label="Steps"
            style={{ display: 'flex', gap: 12, flexWrap: 'wrap', listStyle: 'none', margin: 0, padding: 0 }}
          >
            {STEP_ORDER.map((id: StepId) => (
              <li
                key={id}
                aria-current={id === step ? 'step' : undefined}
                style={{ fontSize: 13, fontWeight: id === step ? 600 : 400, opacity: id === step ? 1 : 0.6 }}
              >
                {STEP_SHORT_TITLES[id]}
              </li>
            ))}
          </ol>

          <div role="status" aria-live="polite">
            {liveMessages.map((message) => (
              <Text key={message} fz={13} c="red">
                {message}
              </Text>
            ))}
          </div>

          {step === 'source' && (
            <SourceStep
              headingRef={headingRef}
              readPreview={readPreview}
              onError={setSourceError}
              onPreview={(preview) => {
                dispatch({ type: 'previewLoaded', preview });
                dispatch({ type: 'next' });
              }}
              onAddress={(baseUrl) => {
                dispatch({ type: 'addressOnly', baseUrl });
                dispatch({ type: 'next' });
              }}
            />
          )}
          {step === 'connection' && (
            <ConnectionStep
              headingRef={headingRef}
              connection={state.connection}
              servers={state.servers}
              warnings={state.warnings}
              secretNames={secretNames}
              onChange={(patch) => dispatch({ type: 'setConnection', patch })}
              onAddSecret={setSecretFor}
            />
          )}
          {step === 'operations' && (
            <OperationsStep
              headingRef={headingRef}
              drafts={state.drafts}
              choices={state.choices}
              errors={errors.operations}
              onToggle={(index, selected) => dispatch({ type: 'toggleOperation', index, selected })}
              onSelect={(indexes, selected) => dispatch({ type: 'selectOperations', indexes, selected })}
              onEffect={(index, effect) => dispatch({ type: 'patchOperation', index, patch: { effect } })}
            />
          )}
          {step === 'names' && (
            <NamesStep
              headingRef={headingRef}
              drafts={state.drafts}
              choices={state.choices}
              errors={errors.operations}
              onChange={(index, patch) => dispatch({ type: 'patchOperation', index, patch })}
            />
          )}
          {step === 'review' && (
            <ReviewStep
              headingRef={headingRef}
              state={state}
              confirmed={confirmed}
              onConfirm={(value) => dispatch({ type: 'confirmSecretHosts', lines: value ? lines : null })}
              onCreateBlocks={(value) => dispatch({ type: 'setCreateBlocks', value })}
            />
          )}
          {step === 'try' && state.created && (
            <TryStep
              headingRef={headingRef}
              projectId={projectId}
              connectorId={state.created.connector.id}
              operations={tryOperations}
            />
          )}
          {step === 'done' && <DoneStep headingRef={headingRef} projectId={projectId} service={state.created} />}

          <Group justify="space-between">
            <div>
              {['connection', 'operations', 'names', 'review'].includes(step) && (
                <Button variant="default" onClick={() => dispatch({ type: 'back' })}>
                  Back
                </Button>
              )}
            </div>
            <Group>
              {['source', 'connection', 'operations', 'names'].includes(step) && (
                <Button onClick={() => dispatch({ type: 'next' })}>Next</Button>
              )}
              {step === 'review' && (
                <Button onClick={create} loading={creating} disabled={!confirmed}>
                  Create service
                </Button>
              )}
              {step === 'try' && <Button onClick={() => dispatch({ type: 'goto', step: 'done' })}>Continue</Button>}
              {step === 'done' && <Button onClick={onClose}>Close</Button>}
            </Group>
          </Group>
        </Stack>
      </Modal>
      <ConfigItemFormModal
        opened={secretFor !== null}
        onClose={() => setSecretFor(null)}
        basePath={companyProjectConfigItemsPath(projectId)}
        defaultType="secret"
        onCreate={saveSecret}
      />
    </>
  );
}
