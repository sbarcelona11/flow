import { Button, Group, Paper, Stack, Text, Textarea } from '@mantine/core';
import { useState } from 'react';

import type StepRun from 'types/generated/StepRun';

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;

function expiryLabel(step: StepRun, now: number): string | null {
  const { timeoutSeconds } = step.stepKindConfig;
  if (!step.startedAt || timeoutSeconds === undefined) return null;
  const left = new Date(step.startedAt).getTime() + timeoutSeconds * 1000 - now;
  if (left <= 0) return 'Expiring…';
  if (left < HOUR) return `Expires in ${Math.max(1, Math.ceil(left / MINUTE))} min`;
  if (left < 48 * HOUR) return `Expires in ${Math.ceil(left / HOUR)} h`;
  return `Expires in ${Math.ceil(left / (24 * HOUR))} days`;
}

interface ApprovalPanelProps {
  step: StepRun;
  now: number;
  canControl: boolean;
  loading: boolean;
  onDecide: (decision: 'approve' | 'reject', note: string) => void;
}

export function ApprovalPanel({ step, now, canControl, loading, onDecide }: ApprovalPanelProps) {
  const [note, setNote] = useState('');
  const expiry = expiryLabel(step, now);

  return (
    <Paper withBorder p="md" radius={0}>
      <Stack gap="sm">
        <Group justify="space-between">
          <Text fw={600}>Approval needed</Text>
          {expiry && (
            <Text size="xs" c="dimmed">
              {expiry}
            </Text>
          )}
        </Group>
        <Text size="sm" c="dimmed">
          {step.stepName}
        </Text>
        {step.stepInstructions && <Text size="sm">{step.stepInstructions}</Text>}
        {canControl && (
          <>
            <Textarea
              id="approval-note"
              label="Note (optional)"
              value={note}
              onChange={(e) => setNote(e.currentTarget.value)}
              autosize
              minRows={2}
            />
            <Group>
              <Button loading={loading} onClick={() => onDecide('approve', note)}>
                Approve
              </Button>
              <Button variant="light" color="red" loading={loading} onClick={() => onDecide('reject', note)}>
                Reject
              </Button>
            </Group>
          </>
        )}
      </Stack>
    </Paper>
  );
}
