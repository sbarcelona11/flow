import { Alert, Button, Code, Select, Stack, Text } from '@mantine/core';
import { type Ref, useState } from 'react';

import { ApiError, apiRequest } from 'shared/lib/apiFetch';
import { testCallCompanyProjectApiConnectorApiOperationPath } from 'shared/routes';
import { SchemaForm } from 'shared/ui/SchemaForm';

import { StepHeading } from './StepHeading';
import { STEP_TITLES } from './wizardState';

export interface TryOperation {
  id: number;
  name: string;
  inputSchema: Record<string, unknown>;
}

interface TestResult {
  ok: boolean;
  status: number | null;
  preview: unknown;
  truncated: boolean;
  error: string | null;
}

interface TryStepProps {
  projectId: number;
  connectorId: number;
  operations: TryOperation[];
  headingRef?: Ref<HTMLHeadingElement>;
  title?: string;
}

const previewText = (preview: unknown): string =>
  typeof preview === 'string' ? preview : preview == null ? '' : JSON.stringify(preview, null, 2);

/** Sends one read request for real. The server refuses anything else; operations passed here are already reads. */
export function TryStep({ projectId, connectorId, operations, headingRef, title = STEP_TITLES.try }: TryStepProps) {
  const [chosenId, setChosenId] = useState<number | null>(operations[0]?.id ?? null);
  const [args, setArgs] = useState<Record<string, unknown>>({});
  const [result, setResult] = useState<TestResult | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [failureStatus, setFailureStatus] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);

  const operation = operations.find((candidate) => candidate.id === chosenId) ?? operations[0];

  const run = async () => {
    if (!operation) return;
    setBusy(true);
    setResult(null);
    setFailure(null);
    setFailureStatus(null);
    try {
      const answer = await apiRequest<TestResult>(
        testCallCompanyProjectApiConnectorApiOperationPath(projectId, connectorId, operation.id),
        { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ arguments: args }) },
      );
      if (answer.ok) setResult(answer);
      else {
        setFailure(answer.error ?? 'The test did not run.');
        setFailureStatus(answer.status);
      }
    } catch (error) {
      setFailure(error instanceof ApiError || error instanceof Error ? error.message : 'The test did not run.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <Stack gap="md">
      {headingRef ? <StepHeading title={title} headingRef={headingRef} /> : null}
      <Text fz={13} c="dimmed">
        Send one real request to check the connection. Only operations that read are offered. Anything that writes can
        only run inside a workflow, behind an approval.
      </Text>
      {operations.length === 0 ? (
        <Text fz={13}>No read operations to try.</Text>
      ) : (
        <>
          {operations.length > 1 && (
            <Select
              label="Operation to try"
              data={operations.map((candidate) => ({ value: String(candidate.id), label: candidate.name }))}
              value={operation ? String(operation.id) : null}
              onChange={(value) => {
                setChosenId(value ? Number(value) : null);
                setArgs({});
                setResult(null);
                setFailure(null);
                setFailureStatus(null);
              }}
              allowDeselect={false}
            />
          )}
          {operation && (
            <SchemaForm key={operation.id} schema={operation.inputSchema} value={args} onChange={setArgs} />
          )}
          <div>
            <Button onClick={run} loading={busy}>
              Send a test request
            </Button>
          </div>
          {failure && (
            <Alert color="red" variant="light" title="The test did not run">
              {failure}
              {failureStatus !== null && <Text fz={13} fw={500}>{`Status ${failureStatus}`}</Text>}
            </Alert>
          )}
          {result && (
            <Stack gap="xs">
              <Text fz={13} fw={500}>
                {`Status ${result.status ?? ''}`.trim()}
              </Text>
              {result.truncated && (
                <Text fz={12} c="dimmed">
                  The answer was cut short.
                </Text>
              )}
              <Code block mah={320} style={{ overflow: 'auto', whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
                {previewText(result.preview)}
              </Code>
            </Stack>
          )}
        </>
      )}
    </Stack>
  );
}
