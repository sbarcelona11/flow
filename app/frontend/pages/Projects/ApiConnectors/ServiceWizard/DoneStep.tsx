import { Link } from '@inertiajs/react';
import { Alert, Button, Group, Stack, Text } from '@mantine/core';
import type { Ref } from 'react';

import { companyProjectWorkflowsPath } from 'shared/routes';

import { StepHeading } from './StepHeading';
import { type CreatedService, STEP_TITLES } from './wizardState';

interface DoneStepProps {
  headingRef: Ref<HTMLHeadingElement>;
  projectId: number;
  service: CreatedService | null;
}

export function DoneStep({ headingRef, projectId, service }: DoneStepProps) {
  const operations = service?.operations.length ?? 0;
  const blocks = service?.blocks.length ?? 0;

  return (
    <Stack gap="md">
      <StepHeading title={STEP_TITLES.done} headingRef={headingRef} />
      {service && (
        <Text
          fz={14}
        >{`${service.connector.name} is ready: ${operations} ${operations === 1 ? 'operation' : 'operations'} and ${blocks} ${blocks === 1 ? 'block' : 'blocks'} created.`}</Text>
      )}
      {service && service.warnings.length > 0 && (
        <Alert color="yellow" variant="light" title="Worth a look">
          <Stack gap={2}>
            {service.warnings.map((warning) => (
              <Text key={warning} fz={13}>
                {warning}
              </Text>
            ))}
          </Stack>
        </Alert>
      )}
      <Group>
        <Button component={Link} href={companyProjectWorkflowsPath(projectId)}>
          Use it in a workflow
        </Button>
        {service && (
          <Button component={Link} href={service.connector.editPath} variant="default">
            Open the connector
          </Button>
        )}
      </Group>
    </Stack>
  );
}
