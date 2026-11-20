import { Alert, Button, Checkbox, Group, Select, Stack, Text, TextInput, Title } from '@mantine/core';
import { type Ref, useMemo, useState } from 'react';

import { ACTION_EFFECTS, allowedEffects, EFFECT_LABELS } from 'shared/lib/actionEffects';

import { StepHeading } from './StepHeading';
import { effectFloor, type ImportDraft, type OperationChoice, STEP_TITLES } from './wizardState';

interface OperationsStepProps {
  headingRef: Ref<HTMLHeadingElement>;
  drafts: ImportDraft[];
  choices: OperationChoice[];
  errors: Record<number, string[]>;
  onToggle: (index: number, selected: boolean) => void;
  onSelect: (indexes: number[], selected: boolean) => void;
  onEffect: (index: number, effect: OperationChoice['effect']) => void;
}

const OTHER = 'Other';

export function OperationsStep({
  headingRef,
  drafts,
  choices,
  errors,
  onToggle,
  onSelect,
  onEffect,
}: OperationsStepProps) {
  const [search, setSearch] = useState('');

  const groups = useMemo(() => {
    const needle = search.trim().toLowerCase();
    const visible = drafts.flatMap((draft, index) =>
      needle === '' ||
      [draft.name, draft.path, draft.summary ?? '', draft.http_method, draft.tag ?? ''].some((text) =>
        text.toLowerCase().includes(needle),
      )
        ? [index]
        : [],
    );
    const byTag = new Map<string, number[]>();
    visible.forEach((index) => {
      const tag = drafts[index].tag?.trim() || OTHER;
      byTag.set(tag, [...(byTag.get(tag) ?? []), index]);
    });
    return [...byTag.entries()];
  }, [drafts, search]);

  const readIndexes = drafts.flatMap((draft, index) => (effectFloor(draft) === 'read' ? [index] : []));

  return (
    <Stack gap="md">
      <StepHeading title={STEP_TITLES.operations} headingRef={headingRef} />
      {drafts.length === 0 ? (
        <Alert color="blue" variant="light">
          No operations were found. You can create the service now and add operations to it later.
        </Alert>
      ) : (
        <>
          <Group align="flex-end" gap="sm">
            <TextInput
              type="search"
              aria-label="Search operations"
              placeholder="Search operations"
              value={search}
              onChange={(e) => setSearch(e.currentTarget.value)}
              style={{ flex: 1 }}
            />
            <Button variant="light" onClick={() => onSelect(readIndexes, true)}>
              Select all reads
            </Button>
            <Button
              variant="subtle"
              onClick={() =>
                onSelect(
                  drafts.map((_, index) => index),
                  false,
                )
              }
            >
              Clear selection
            </Button>
          </Group>
          {groups.length === 0 && (
            <Text fz={13} c="dimmed">
              Nothing matches that search.
            </Text>
          )}
          {groups.map(([tag, indexes]) => (
            <Stack key={tag} gap="xs">
              <Title order={3} fz={14}>
                {tag}
              </Title>
              {indexes.map((index) => {
                const draft = drafts[index];
                const choice = choices[index];
                return (
                  <Stack key={index} gap={4} pl="sm">
                    <Group justify="space-between" align="flex-start" wrap="nowrap">
                      <Checkbox
                        label={`${draft.http_method} ${draft.path}`}
                        description={draft.summary ?? draft.name}
                        checked={choice.selected}
                        onChange={(e) => onToggle(index, e.currentTarget.checked)}
                      />
                      {choice.selected && (
                        <Select
                          aria-label={`Effect for ${draft.name}`}
                          data={allowedEffects(effectFloor(draft)).map((value) => ({
                            value,
                            label: EFFECT_LABELS[value],
                          }))}
                          value={choice.effect}
                          onChange={(value) =>
                            value &&
                            ACTION_EFFECTS.includes(value as never) &&
                            onEffect(index, value as OperationChoice['effect'])
                          }
                          allowDeselect={false}
                          w={160}
                        />
                      )}
                    </Group>
                    {(errors[index] ?? []).map((message) => (
                      <Text key={message} fz={12} c="red" ml={28}>
                        {message}
                      </Text>
                    ))}
                  </Stack>
                );
              })}
            </Stack>
          ))}
        </>
      )}
    </Stack>
  );
}
