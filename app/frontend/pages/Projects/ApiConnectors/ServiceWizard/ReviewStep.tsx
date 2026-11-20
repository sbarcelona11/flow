import { Checkbox, Group, List, Stack, Text } from '@mantine/core';
import type { Ref } from 'react';

import { EFFECT_LABELS } from 'shared/lib/actionEffects';

import { AUTH_LABELS } from '../apiConnectorLabels';

import { StepHeading } from './StepHeading';
import { hostOf, secretNames, selectedIndexes, STEP_TITLES, type WizardState } from './wizardState';

interface ReviewStepProps {
  headingRef: Ref<HTMLHeadingElement>;
  state: WizardState;
  confirmed: boolean;
  onConfirm: (confirmed: boolean) => void;
  onCreateBlocks: (value: boolean) => void;
}

export function ReviewStep({ headingRef, state, confirmed, onConfirm, onCreateBlocks }: ReviewStepProps) {
  const { connection, drafts, choices } = state;
  const host = hostOf(connection.baseUrl) ?? connection.baseUrl;
  const secrets = secretNames(connection);
  const indexes = selectedIndexes(state);

  return (
    <Stack gap="md">
      <StepHeading title={STEP_TITLES.review} headingRef={headingRef} />
      <Stack gap={2}>
        <Text fz={14} fw={500}>
          {connection.name}
        </Text>
        <Text fz={13} c="dimmed">{`Calls go to ${host}. ${AUTH_LABELS[connection.authType]}.`}</Text>
      </Stack>

      {secrets.length > 0 && (
        <Stack gap="xs">
          {secrets.map((name) => (
            <Text key={name} fz={14} fw={500}>{`${name} is sent to ${host}`}</Text>
          ))}
          <Checkbox
            label={`I understand ${secrets.join(' and ')} will be sent to ${host}`}
            description="Anyone who can edit this service can change where it goes. Check that this is the host you expect."
            checked={confirmed}
            onChange={(e) => onConfirm(e.currentTarget.checked)}
          />
        </Stack>
      )}

      {indexes.length === 0 ? (
        <Text fz={13} c="dimmed">
          No operations are chosen. Go back and choose at least one: a service needs one.
        </Text>
      ) : (
        <List aria-label="Operations to create" spacing={4} listStyleType="none">
          {indexes.map((index) => (
            <List.Item key={index}>
              <Group gap="sm" wrap="nowrap">
                <Text
                  fz={13}
                  style={{ flex: 1 }}
                >{`${drafts[index].http_method} ${drafts[index].path} — ${choices[index].label}`}</Text>
                <Text fz={12} fw={500}>
                  {EFFECT_LABELS[choices[index].effect]}
                </Text>
              </Group>
            </List.Item>
          ))}
        </List>
      )}

      <Checkbox
        label="Also create a block for each operation"
        description="A block is a ready-made step for a workflow."
        checked={state.createBlocks}
        onChange={(e) => onCreateBlocks(e.currentTarget.checked)}
      />
    </Stack>
  );
}
