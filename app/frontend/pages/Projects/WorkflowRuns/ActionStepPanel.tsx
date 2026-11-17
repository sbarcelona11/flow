import { Anchor, Badge, Group, Paper, Stack, Text } from '@mantine/core';

import type StepRun from 'types/generated/StepRun';
import type WorkflowRunAsset from 'types/generated/WorkflowRunAsset';

const FAILURE_COPY: Record<string, (server: string | null, rest: boolean) => string> = {
  action_outcome_unknown: () => 'May already have run — not sent again',
  action_auth_required: (server) => `Needs ${server ?? 'the server'} to be connected`,
  action_tool_drifted: () => 'The tool changed since it was approved',
  action_invalid_arguments: () => "The arguments don't fit the tool",
  action_output_too_large: () => 'The output was too large to keep',
  action_target_missing: (_server, rest) => `The ${rest ? 'operation' : 'tool'} is no longer available in this project`,
  action_not_approved: () => 'Waiting on an approval that did not happen',
  action_failed: () => 'The call failed',
};

const OUTCOME_LABELS: Record<string, string> = {
  succeeded: 'Succeeded',
  failed: 'Failed',
  unknown: 'Outcome unknown',
};

function durationLabel(ms: number): string {
  return ms < 1000 ? `${ms} ms` : `${(ms / 1000).toFixed(1)} s`;
}

function actionTarget(call: NonNullable<StepRun['actionCall']>): string {
  return call.targetType === 'wrapper'
    ? `Runs ${call.toolName ?? 'a Wrapper'}`
    : `Calls ${call.serverName} · ${call.toolName}`;
}

interface ActionStepPanelProps {
  step: StepRun;
  assets: WorkflowRunAsset[];
}

export function ActionStepPanel({ step, assets }: ActionStepPanelProps) {
  const call = step.actionCall;
  const output = assets.filter((asset) => asset.producedByStepRunId === step.id);
  const failure = step.errorCategory ? FAILURE_COPY[step.errorCategory] : undefined;
  const running = step.state === 'running' && (!call || call.outcome === null);

  return (
    <Paper component="section" aria-label={`Action: ${step.stepName ?? 'Action'}`} withBorder p="md" radius={0}>
      <Stack gap="xs">
        <Group justify="space-between">
          <Text fw={600}>{step.stepName ?? 'Action'}</Text>
          {call && (
            <Badge variant="light" color={call.effect === 'read' ? 'gray' : 'orange'}>
              {call.effect}
            </Badge>
          )}
        </Group>
        {call && <Text size="sm">{actionTarget(call)}</Text>}
        {running && (
          <Text size="sm" c="dimmed">
            Running…
          </Text>
        )}
        {call?.outcome && (
          <Text size="sm" c="dimmed">
            {OUTCOME_LABELS[call.outcome] ?? call.outcome}
            {call.durationMs !== null ? ` · ${durationLabel(call.durationMs)}` : ''}
          </Text>
        )}
        {step.state === 'failed' && (
          <>
            {failure && (
              <Text size="sm" fw={500} c="red">
                {failure(call?.serverName ?? null, call?.targetType === 'rest_operation')}
              </Text>
            )}
            {(call?.error ?? step.errorMessage) && (
              <Text size="sm" c="dimmed">
                {call?.error ?? step.errorMessage}
              </Text>
            )}
          </>
        )}
        {output.map((asset) => (
          <Group gap="xs" key={asset.id}>
            <Text size="sm">Output</Text>
            {asset.downloadUrl ? (
              <Anchor size="sm" href={asset.downloadUrl} target="_blank">
                {asset.name}
              </Anchor>
            ) : (
              <Text size="sm">{asset.name}</Text>
            )}
          </Group>
        ))}
      </Stack>
    </Paper>
  );
}
