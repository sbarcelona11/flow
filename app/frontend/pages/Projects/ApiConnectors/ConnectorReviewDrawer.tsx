import { Alert, Button, Group, Loader, Stack, Text } from '@mantine/core';
import { useCallback, useEffect, useState } from 'react';

import type { ApiConnector, ApiOperation, ModuleDefinition } from '@/types/generated';

import { ApiError, apiRequest } from 'shared/lib/apiFetch';
import { formatCostCents } from 'shared/lib/formatUsage';
import {
  AdvancedJson,
  CallLine,
  EffectLine,
  ReviewProblem,
  ReviewSection,
  SecretLines,
} from 'shared/resources/connectors/reviewParts';
import {
  CHANGED_WHILE_OPEN,
  isContentChanged,
  plainLine,
  proposedBy,
  schemaSummary,
} from 'shared/resources/connectors/reviewText';
import {
  approveCompanyProjectApiConnectorPath,
  rejectCompanyProjectApiConnectorPath,
  reviewCompanyProjectApiConnectorPath,
} from 'shared/routes';
import { ResourceDrawer } from 'shared/ui/ResourceDrawer';

import { AUTH_LABELS } from './apiConnectorLabels';

interface ConnectorReview {
  connector: ApiConnector;
  host: string;
  secretBindings: string[];
  operations: ApiOperation[];
  blocks: ModuleDefinition[];
}

interface ConnectorReviewDrawerProps {
  projectId: number;
  connectorId: number | null;
  canAct: boolean;
  onClose: () => void;
  onChanged: () => void;
}

const JSON_HEADERS = { 'Content-Type': 'application/json' };

const STATE_TEXT = { waiting: 'Waiting for review', reviewed: 'Approved', rejected: 'Rejected' } as const;

const failure = (error: unknown) =>
  error instanceof ApiError || error instanceof Error ? error.message : 'That did not work. Try again.';

/**
 * What a connector asks to be trusted with: the host, which secret goes there, and every operation proposed with it.
 * Approve sends the digests of what is shown here, and nothing is approved without that click.
 */
export function ConnectorReviewDrawer({
  projectId,
  connectorId,
  canAct,
  onClose,
  onChanged,
}: ConnectorReviewDrawerProps) {
  const [review, setReview] = useState<ConnectorReview | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [changed, setChanged] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(
    async (id: number) => {
      try {
        setReview(await apiRequest<ConnectorReview>(reviewCompanyProjectApiConnectorPath(projectId, id)));
      } catch (error) {
        setProblem(failure(error));
      }
    },
    [projectId],
  );

  useEffect(() => {
    setReview(null);
    setProblem(null);
    setChanged(false);
    if (connectorId !== null) void load(connectorId);
  }, [connectorId, load]);

  const connector = review?.connector ?? null;
  const waitingOperations = (review?.operations ?? []).filter((operation) => operation.reviewState === 'waiting');
  const connectorWaiting = connector?.reviewState === 'waiting';
  const nothingToDecide = !connectorWaiting && waitingOperations.length === 0;

  const send = async (path: string, body: unknown) => {
    if (!connector) return;
    setBusy(true);
    setProblem(null);
    try {
      await apiRequest(path, { method: 'POST', headers: JSON_HEADERS, body: JSON.stringify(body) });
      onChanged();
      onClose();
    } catch (error) {
      if (isContentChanged(error)) {
        setChanged(true);
        await load(connector.id);
      } else {
        setProblem(failure(error));
      }
    } finally {
      setBusy(false);
    }
  };

  const approve = () => {
    if (!connector) return;
    void send(approveCompanyProjectApiConnectorPath(projectId, connector.id), {
      expectedDigest: connector.reviewDigest,
      operationDigests: Object.fromEntries(
        waitingOperations.map((operation) => [String(operation.id), operation.reviewDigest]),
      ),
    });
  };

  const reject = () => {
    if (!connector) return;
    void send(rejectCompanyProjectApiConnectorPath(projectId, connector.id), {
      operationIds: connectorWaiting ? undefined : waitingOperations.map((operation) => operation.id),
    });
  };

  const approveLabel = connectorWaiting
    ? 'Approve and enable'
    : `Approve ${waitingOperations.length} ${waitingOperations.length === 1 ? 'operation' : 'operations'}`;

  return (
    <ResourceDrawer
      opened={connectorId !== null}
      onClose={onClose}
      title={connector ? `Review: ${connector.name}` : 'Review a connector'}
      footer={
        canAct && connector && !nothingToDecide ? (
          <Group grow>
            <Button variant="default" disabled={busy} onClick={reject}>
              Reject
            </Button>
            <Button loading={busy} onClick={approve}>
              {approveLabel}
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
        {!review && !problem && <Loader size="sm" aria-label="Loading the connector" />}
        {review && connector && (
          <>
            <Stack gap={2}>
              <Text fz={14} fw={600}>
                {plainLine(connector.name, 120)}
              </Text>
              <Text fz={12} c="dimmed">
                {STATE_TEXT[connector.reviewState]}
              </Text>
              <Text fz={12} c="dimmed">
                {proposedBy(connector.origin, null, null)}
              </Text>
              {connector.description && <Text fz={13}>{plainLine(connector.description, 500)}</Text>}
            </Stack>

            <ReviewSection title="Sent with every call">
              <Text
                fz={13}
                ff="monospace"
                style={{ wordBreak: 'break-all' }}
              >{`Address: ${plainLine(connector.baseUrl, 300)}`}</Text>
              <Text fz={13}>{`Authentication: ${AUTH_LABELS[connector.authType]}`}</Text>
              {connector.authConfig.header_name && (
                <Text
                  fz={13}
                >{`The secret goes in the header: ${plainLine(connector.authConfig.header_name, 80)}`}</Text>
              )}
              {connector.authConfig.query_param && (
                <Text
                  fz={13}
                >{`The secret goes in the query parameter: ${plainLine(connector.authConfig.query_param, 80)}`}</Text>
              )}
              {Object.entries(connector.defaultHeaders).length === 0 ? (
                <Text fz={13}>No other headers.</Text>
              ) : (
                Object.entries(connector.defaultHeaders).map(([name, value]) => (
                  <Text key={name} fz={13} ff="monospace" style={{ wordBreak: 'break-all' }}>
                    {`Header ${plainLine(name, 80)}: ${plainLine(value, 200)}`}
                  </Text>
                ))
              )}
            </ReviewSection>

            <ReviewSection title="Which secret goes where">
              <SecretLines bindings={review.secretBindings} />
            </ReviewSection>

            <ReviewSection title={`Operations (${review.operations.length})`}>
              {review.operations.length === 0 && <Text fz={13}>None.</Text>}
              <Stack gap="sm">
                {review.operations.map((operation) => (
                  <Stack key={operation.id} gap={2}>
                    <CallLine
                      method={operation.httpMethod}
                      path={plainLine(operation.path, 300)}
                      host={plainLine(review.host, 200)}
                    />
                    <Text fz={13}>{plainLine(operation.name, 120)}</Text>
                    {operation.summary && (
                      <Text fz={12} c="dimmed">
                        {plainLine(operation.summary)}
                      </Text>
                    )}
                    {operation.description && (
                      <Text fz={12} c="dimmed">
                        {plainLine(operation.description, 500)}
                      </Text>
                    )}
                    <EffectLine effect={operation.effect} />
                    <Text fz={12} c="dimmed">
                      {operation.costCents == null
                        ? 'No cost recorded.'
                        : `Counted as ${formatCostCents(operation.costCents)} per call.`}
                    </Text>
                    {schemaSummary(operation.inputSchema).length > 0 && (
                      <Text fz={12} ff="monospace" style={{ whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
                        {`Takes: ${schemaSummary(operation.inputSchema).join('; ')}`}
                      </Text>
                    )}
                    <Text fz={12} c="dimmed">
                      {STATE_TEXT[operation.reviewState]}
                    </Text>
                  </Stack>
                ))}
              </Stack>
            </ReviewSection>

            <ReviewSection title={`Blocks (${review.blocks.length})`}>
              {review.blocks.length === 0 ? (
                <Text fz={13}>No blocks use this connector yet.</Text>
              ) : (
                <>
                  {review.blocks.map((block) => (
                    <Text
                      key={block.id}
                      fz={13}
                    >{`${plainLine(block.label, 120)} (${plainLine(block.key, 120)}): ${STATE_TEXT[block.reviewState].toLowerCase()}`}</Text>
                  ))}
                  <Text fz={12} c="dimmed">
                    Blocks are reviewed separately, on the Blocks tab.
                  </Text>
                </>
              )}
            </ReviewSection>

            <AdvancedJson
              label="Advanced: the operations as written"
              value={review.operations.map(({ name, httpMethod, path, inputSchema }) => ({
                name,
                httpMethod,
                path,
                inputSchema,
              }))}
            />
          </>
        )}
      </Stack>
    </ResourceDrawer>
  );
}
