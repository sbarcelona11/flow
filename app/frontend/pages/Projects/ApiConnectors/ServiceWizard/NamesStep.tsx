import { Stack, Text, Textarea, TextInput } from '@mantine/core';
import type { Ref } from 'react';

import { StepHeading } from './StepHeading';
import { type ImportDraft, type OperationChoice, selectedIndexesOf, STEP_TITLES } from './wizardState';

interface NamesStepProps {
  headingRef: Ref<HTMLHeadingElement>;
  drafts: ImportDraft[];
  choices: OperationChoice[];
  errors: Record<number, string[]>;
  onChange: (index: number, patch: Partial<Pick<OperationChoice, 'label' | 'description'>>) => void;
}

export function NamesStep({ headingRef, drafts, choices, errors, onChange }: NamesStepProps) {
  const indexes = selectedIndexesOf(choices);

  return (
    <Stack gap="md">
      <StepHeading title={STEP_TITLES.names} headingRef={headingRef} />
      {indexes.length === 0 && (
        <Text fz={13} c="dimmed">
          No operations were chosen, so there is nothing to name.
        </Text>
      )}
      {indexes.map((index) => (
        <fieldset key={index} style={{ border: '1px solid var(--app-border-default)', borderRadius: 8, padding: 12 }}>
          <legend
            style={{ fontSize: 13, padding: '0 6px' }}
          >{`${drafts[index].http_method} ${drafts[index].path}`}</legend>
          <Stack gap="xs">
            <TextInput
              label="Name"
              description="Shown when someone picks this operation or block."
              value={choices[index].label}
              onChange={(e) => onChange(index, { label: e.currentTarget.value })}
              required
            />
            <Textarea
              label="Description"
              autosize
              minRows={2}
              value={choices[index].description}
              onChange={(e) => onChange(index, { description: e.currentTarget.value })}
            />
            {(errors[index] ?? []).map((message) => (
              <Text key={message} fz={12} c="red">
                {message}
              </Text>
            ))}
          </Stack>
        </fieldset>
      ))}
    </Stack>
  );
}
