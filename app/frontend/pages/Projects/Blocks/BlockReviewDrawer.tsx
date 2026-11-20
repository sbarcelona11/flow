import { Alert, Button, Group, Loader, Stack, Text } from '@mantine/core';
import { useCallback, useEffect, useState } from 'react';

import type { ModuleDefinition } from '@/types/generated';

import { ApiError, apiRequest } from 'shared/lib/apiFetch';
import {
  AdvancedJson,
  CallLine,
  EffectLine,
  ReviewProblem,
  ReviewSection,
  SecretLines,
} from 'shared/resources/connectors/reviewParts';
import { CHANGED_WHILE_OPEN, isContentChanged, plainLine, proposedBy } from 'shared/resources/connectors/reviewText';
import {
  approveCompanyProjectModuleDefinitionPath,
  companyProjectModuleDefinitionPath,
  rejectCompanyProjectModuleDefinitionPath,
} from 'shared/routes';
import { ResourceDrawer } from 'shared/ui/ResourceDrawer';

interface BlockReviewDrawerProps {
  projectId: number;
  definitionId: number | null;
  canAct: boolean;
  onClose: () => void;
  onChanged: () => void;
}

const JSON_HEADERS = { 'Content-Type': 'application/json' };

const asRecord = (value: unknown): Record<string, unknown> =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : {};

const portLines = (ports: unknown) =>
  Object.entries(asRecord(ports)).map(([name, type]) => plainLine(`${name}: ${String(type)}`, 120));

const settingNames = (manifest: Record<string, unknown> | null) =>
  Object.keys(asRecord(asRecord(manifest?.config).properties));

const failure = (error: unknown) =>
  error instanceof ApiError || error instanceof Error ? error.message : 'That did not work. Try again.';

/** Approve and Reject only ever run on a click, and Approve sends the digest of the definition shown here. */
export function BlockReviewDrawer({ projectId, definitionId, canAct, onClose, onChanged }: BlockReviewDrawerProps) {
  const [definition, setDefinition] = useState<ModuleDefinition | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [changed, setChanged] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(
    async (id: number) => {
      try {
        setDefinition(await apiRequest<ModuleDefinition>(companyProjectModuleDefinitionPath(projectId, id)));
      } catch (error) {
        setProblem(failure(error));
      }
    },
    [projectId],
  );

  useEffect(() => {
    setDefinition(null);
    setProblem(null);
    setChanged(false);
    if (definitionId !== null) void load(definitionId);
  }, [definitionId, load]);

  const post = async (path: string, body?: unknown) => {
    if (!definition) return;
    setBusy(true);
    setProblem(null);
    try {
      await apiRequest(path, { method: 'POST', headers: JSON_HEADERS, body: JSON.stringify(body ?? {}) });
      onChanged();
      onClose();
    } catch (error) {
      if (isContentChanged(error)) {
        setChanged(true);
        await load(definition.id);
      } else {
        setProblem(failure(error));
      }
    } finally {
      setBusy(false);
    }
  };

  const waiting = definition?.reviewState === 'waiting';
  const manifest = definition?.manifest ?? null;
  const calls = definition?.calls ?? null;
  const settings = settingNames(manifest);
  const ports = asRecord(asRecord(manifest).ports);
  const portsIn = portLines(ports.in);
  const portsOut = portLines(ports.out);

  return (
    <ResourceDrawer
      opened={definitionId !== null}
      onClose={onClose}
      title={definition ? `Review: ${definition.label}` : 'Review a block'}
      footer={
        canAct && waiting && definition ? (
          <Group grow>
            <Button
              variant="default"
              disabled={busy}
              onClick={() => post(rejectCompanyProjectModuleDefinitionPath(projectId, definition.id))}
            >
              Reject
            </Button>
            <Button
              loading={busy}
              onClick={() =>
                post(approveCompanyProjectModuleDefinitionPath(projectId, definition.id), {
                  expectedDigest: definition.reviewDigest,
                })
              }
            >
              Approve and enable
            </Button>
          </Group>
        ) : undefined
      }
    >
      <Stack gap="md">
        {changed && (
          <Alert color="yellow" variant="light" role="alert">
            {CHANGED_WHILE_OPEN}
          </Alert>
        )}
        <ReviewProblem message={problem} />
        {!definition && !problem && <Loader size="sm" aria-label="Loading the block" />}
        {definition && (
          <>
            <Stack gap={2}>
              <Text fz={14} fw={600}>
                {plainLine(definition.label, 120)}
              </Text>
              <Text fz={12} c="dimmed" ff="monospace">
                {plainLine(definition.key, 120)}
              </Text>
              <Text fz={12} c="dimmed">
                {proposedBy(definition.origin, definition.originSessionId, definition.createdBy?.name ?? null)}
              </Text>
              {definition.description && <Text fz={13}>{plainLine(definition.description, 500)}</Text>}
            </Stack>

            {definition.status === 'invalid' && definition.reason && (
              <Alert color="red" variant="light" title="This block is not usable yet">
                {plainLine(definition.reason, 300)}
              </Alert>
            )}

            <ReviewSection title="What it calls">
              {calls?.resolved && calls.method && calls.path && calls.host ? (
                <>
                  <CallLine
                    method={plainLine(calls.method, 10)}
                    path={plainLine(calls.path, 300)}
                    host={plainLine(calls.host, 200)}
                  />
                  <Text
                    fz={12}
                    c="dimmed"
                  >{`The ${plainLine(calls.operation, 120)} operation of ${plainLine(calls.connector, 120)}.`}</Text>
                  {calls.connectorState && calls.connectorState !== 'reviewed' && (
                    <Text fz={12} c="orange">
                      {`That connector is ${calls.connectorState === 'waiting' ? 'waiting for review' : calls.connectorState}, so the block cannot run yet.`}
                    </Text>
                  )}
                </>
              ) : (
                <Text fz={13}>
                  {calls
                    ? 'The connector or operation it names was not found in this project.'
                    : 'This block does not call a REST API.'}
                </Text>
              )}
            </ReviewSection>

            {calls?.resolved && (
              <ReviewSection title="Which secret goes where">
                <SecretLines bindings={calls.secretBindings ?? []} />
              </ReviewSection>
            )}

            <ReviewSection title="What it does">
              <EffectLine effect={calls?.effect ?? (asRecord(manifest).effect as string | undefined)} />
            </ReviewSection>

            <ReviewSection title="Settings and ports">
              <Text fz={13}>
                {settings.length > 0
                  ? `Settings: ${settings.map((name) => plainLine(name, 80)).join(', ')}`
                  : 'No settings.'}
              </Text>
              <Text fz={13}>{portsIn.length > 0 ? `Takes: ${portsIn.join(', ')}` : 'Takes nothing.'}</Text>
              <Text fz={13}>{portsOut.length > 0 ? `Gives: ${portsOut.join(', ')}` : 'Gives nothing.'}</Text>
            </ReviewSection>

            {definition.reviewState === 'rejected' && <Text fz={13}>This block was rejected.</Text>}
            {definition.reviewState === 'reviewed' && <Text fz={13}>This block was already reviewed.</Text>}

            <AdvancedJson value={manifest} label="Advanced: the manifest" />
          </>
        )}
      </Stack>
    </ResourceDrawer>
  );
}
