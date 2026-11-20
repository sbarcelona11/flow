import { Alert, Button, Group, Modal, Select, Stack, Text } from '@mantine/core';
import { useState } from 'react';

import type { ModuleBlock } from '@/types/generated';

import { plainLine } from 'shared/resources/connectors/reviewText';

import { stepKey } from './builderDraft';
import { type BindingOption } from './canvas/connections';

const optionValue = (option: BindingOption) => `${option.stepId}:${option.port}`;
const outputToken = (option: BindingOption) =>
  `{{output:${stepKey(option.stepId)}:${option.file ?? `${option.port}.json`}}}`;

interface DialogProps {
  block: ModuleBlock;
  options: BindingOption[];
  busy: boolean;
  problem: string | null;
  onConnect: (bindings: Record<string, string>) => void;
  onClose: () => void;
}

/** Asks which earlier output each input of the block reads. Every one may be left unconnected, or all skipped. */
export function ConnectInputsDialog({ block, options, busy, problem, onConnect, onClose }: DialogProps) {
  const ports = Object.entries(block.composite?.ports.in ?? {});
  const [chosen, setChosen] = useState<Record<string, string | null>>({});
  const bindings = () =>
    Object.fromEntries(
      ports.flatMap(([name]) => {
        const option = options.find((o) => optionValue(o) === chosen[name]);
        return option ? [[name, outputToken(option)]] : [];
      }),
    );
  const data = options.map((option) => ({
    value: optionValue(option),
    label: `${plainLine(option.stepName, 80)}: ${plainLine(option.port, 60)} (${option.type ?? 'any'})`,
  }));

  return (
    <Modal opened onClose={onClose} title={`Connect inputs of ${plainLine(block.label, 80)}`} size="lg">
      <Stack gap="md">
        <Text size="sm">
          Pick the earlier output each input reads. You can connect an input later from the group, or leave it.
        </Text>
        {problem && (
          <Alert color="red" role="alert" title="The block was not inserted">
            {problem}
          </Alert>
        )}
        {ports.map(([name, port]) => (
          <Select
            key={name}
            label={name}
            description={[
              port.type ? `Type ${plainLine(port.type, 60)}` : null,
              plainLine(port.description, 200) || null,
            ]
              .filter(Boolean)
              .join('. ')}
            placeholder="Not connected"
            data={data}
            value={chosen[name] ?? null}
            onChange={(value) => setChosen((was) => ({ ...was, [name]: value }))}
            clearable
            comboboxProps={{ withinPortal: true }}
            nothingFoundMessage="No earlier step has an output port"
          />
        ))}
        <Group justify="flex-end">
          <Button variant="default" disabled={busy} onClick={() => onConnect({})}>
            Insert without connecting
          </Button>
          <Button loading={busy} onClick={() => onConnect(bindings())}>
            Insert
          </Button>
        </Group>
      </Stack>
    </Modal>
  );
}
