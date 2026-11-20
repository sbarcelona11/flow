import { Alert, Button, Group, Modal, Select, Stack, Text, Textarea, TextInput, UnstyledButton } from '@mantine/core';
import { useMemo, useState } from 'react';

import { ACTION_EFFECTS, type ActionEffect, allowedEffects, EFFECT_LABELS } from 'shared/lib/actionEffects';
import { ApiError, apiRequest } from 'shared/lib/apiFetch';
import {
  CallLine,
  EffectLine,
  ReviewProblem,
  ReviewSection,
  SecretLines,
} from 'shared/resources/connectors/reviewParts';
import { companyProjectModuleDefinitionsPath, newVersionCompanyProjectModuleDefinitionPath } from 'shared/routes';

export interface BlockSourceOperation {
  id: number;
  name: string;
  summary: string | null;
  effect: ActionEffect;
  httpMethod: string;
  path: string;
  connectorName: string;
  host: string;
  secretBindings: string[];
}

interface NewBlockDialogProps {
  projectId: number;
  operations: BlockSourceOperation[];
  /** Set to make version N+1 of an existing block instead of a new one. */
  previous?: { id: number; label: string; key: string } | null;
  opened: boolean;
  onClose: () => void;
  onCreated: () => void;
}

type Stage = 'form' | 'summary' | 'done';

const DEFAULT_NAMESPACE = 'local';

const isEffect = (value: string | null): value is ActionEffect => ACTION_EFFECTS.some((effect) => effect === value);

/** Makes a block from an operation in a few choices. The pasted manifest is the Advanced way and replaces them. */
export function NewBlockDialog({
  projectId,
  operations,
  previous = null,
  opened,
  onClose,
  onCreated,
}: NewBlockDialogProps) {
  const [stage, setStage] = useState<Stage>('form');
  const [operationId, setOperationId] = useState<string | null>(null);
  const [label, setLabel] = useState(previous?.label ?? '');
  const [description, setDescription] = useState('');
  const [effect, setEffect] = useState<ActionEffect | null>(null);
  const [advanced, setAdvanced] = useState(false);
  const [namespace, setNamespace] = useState(DEFAULT_NAMESPACE);
  const [manifest, setManifest] = useState('');
  const [problem, setProblem] = useState<string | null>(null);
  const [warnings, setWarnings] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);

  const operation = operations.find((candidate) => String(candidate.id) === operationId) ?? null;
  const pasted = manifest.trim() !== '';
  const options = useMemo(() => {
    const groups = new Map<string, { value: string; label: string }[]>();
    for (const candidate of operations) {
      const items = groups.get(candidate.connectorName) ?? [];
      items.push({ value: String(candidate.id), label: candidate.name });
      groups.set(candidate.connectorName, items);
    }
    return [...groups].map(([group, items]) => ({ group, items }));
  }, [operations]);
  const effectChoices = operation ? allowedEffects(operation.effect) : ACTION_EFFECTS;
  const effectiveEffect = effect && effectChoices.includes(effect) ? effect : (operation?.effect ?? null);
  const ready = pasted || (operation !== null && label.trim() !== '');

  const create = async () => {
    setBusy(true);
    setProblem(null);
    const body = pasted
      ? { manifest }
      : {
          fromOperation: {
            apiOperationId: operation?.id,
            label: label.trim(),
            description: description.trim(),
            effect: effectiveEffect,
            namespace: namespace.trim() || DEFAULT_NAMESPACE,
          },
        };
    const path = previous
      ? newVersionCompanyProjectModuleDefinitionPath(projectId, previous.id)
      : companyProjectModuleDefinitionsPath(projectId);
    try {
      const created = await apiRequest<{ warnings?: string[] }>(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      onCreated();
      if (created.warnings && created.warnings.length > 0) {
        setWarnings(created.warnings);
        setStage('done');
      } else {
        onClose();
      }
    } catch (error) {
      setProblem(error instanceof ApiError || error instanceof Error ? error.message : 'The block was not created.');
      setStage('form');
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      opened={opened}
      onClose={onClose}
      title={previous ? `New version of ${previous.label}` : 'New block'}
      size="lg"
    >
      <Stack gap="md">
        <ReviewProblem message={problem} />

        {stage === 'form' && (
          <>
            <Select
              label="Operation"
              description="The REST operation this block calls."
              placeholder="Choose an operation"
              data={options}
              value={operationId}
              onChange={(value) => {
                setOperationId(value);
                setEffect(null);
              }}
              searchable
              allowDeselect={false}
              disabled={pasted}
            />
            <TextInput
              label="Label"
              value={label}
              onChange={(e) => setLabel(e.currentTarget.value)}
              disabled={pasted}
            />
            <Textarea
              label="Description"
              description="Optional. Shown when someone picks the block."
              value={description}
              onChange={(e) => setDescription(e.currentTarget.value)}
              autosize
              minRows={2}
              disabled={pasted}
            />
            {operation && (
              <Select
                label="Effect"
                description="It can be raised above the operation's own effect, never lowered."
                data={effectChoices.map((value) => ({ value, label: EFFECT_LABELS[value] }))}
                value={effectiveEffect}
                onChange={(value) => isEffect(value) && setEffect(value)}
                allowDeselect={false}
                disabled={pasted}
              />
            )}
            <UnstyledButton onClick={() => setAdvanced((open) => !open)} aria-expanded={advanced} aria-label="Advanced">
              <Text fz={13}>{advanced ? 'Hide advanced options' : 'Advanced options'}</Text>
            </UnstyledButton>
            {advanced && (
              <Stack gap="sm">
                {!previous && (
                  <TextInput
                    label="Namespace"
                    description="Blocks made here live in local unless you say otherwise."
                    value={namespace}
                    onChange={(e) => setNamespace(e.currentTarget.value)}
                    disabled={pasted}
                  />
                )}
                <Textarea
                  label="Paste a manifest instead"
                  description="YAML or JSON. When this has text, the choices above are ignored."
                  value={manifest}
                  onChange={(e) => setManifest(e.currentTarget.value)}
                  autosize
                  minRows={4}
                  maxRows={12}
                  styles={{ input: { fontFamily: 'var(--mantine-font-family-monospace)' } }}
                />
              </Stack>
            )}
            <Group justify="flex-end">
              <Button variant="default" onClick={onClose}>
                Cancel
              </Button>
              <Button disabled={!ready} onClick={() => setStage('summary')}>
                Review
              </Button>
            </Group>
          </>
        )}

        {stage === 'summary' && (
          <>
            {pasted || !operation ? (
              <Text fz={13}>
                This creates a block from the manifest you pasted. It is checked when you create it, and what it calls
                is shown in the block&apos;s review afterwards.
              </Text>
            ) : (
              <>
                <Text fz={14} fw={600}>{`${label.trim()} (${namespace.trim() || DEFAULT_NAMESPACE})`}</Text>
                <ReviewSection title="What it calls">
                  <CallLine method={operation.httpMethod} path={operation.path} host={operation.host} />
                  <Text fz={12} c="dimmed">{`The ${operation.name} operation of ${operation.connectorName}.`}</Text>
                </ReviewSection>
                <ReviewSection title="Which secret goes where">
                  <SecretLines bindings={operation.secretBindings} />
                </ReviewSection>
                <ReviewSection title="What it does">
                  <EffectLine effect={effectiveEffect ?? undefined} />
                </ReviewSection>
              </>
            )}
            <Text fz={12} c="dimmed">
              Creating it makes it available in workflows straight away.
            </Text>
            <Group justify="flex-end">
              <Button variant="default" onClick={() => setStage('form')}>
                Back
              </Button>
              <Button loading={busy} onClick={create}>
                Create block
              </Button>
            </Group>
          </>
        )}

        {stage === 'done' && (
          <>
            <Alert color="yellow" variant="light" title="Created, with notes">
              <Stack gap={2}>
                {warnings.map((warning) => (
                  <Text key={warning} fz={13}>
                    {warning}
                  </Text>
                ))}
              </Stack>
            </Alert>
            <Group justify="flex-end">
              <Button onClick={onClose}>Close</Button>
            </Group>
          </>
        )}
      </Stack>
    </Modal>
  );
}
