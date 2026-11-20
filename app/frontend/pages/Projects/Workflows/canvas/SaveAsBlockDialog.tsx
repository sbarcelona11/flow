import { Alert, Button, Checkbox, Group, Modal, Stack, Text, Textarea, TextInput } from '@mantine/core';
import { useState } from 'react';

import type { ModuleDefinition, Step } from '@/types/generated';

import { ApiError, apiRequest } from 'shared/lib/apiFetch';
import { plainLine } from 'shared/resources/connectors/reviewText';
import { fromStepsCompanyProjectModuleDefinitionsPath } from 'shared/routes';

interface Props {
  projectId: number;
  workflowId: number;
  /** The draft's steps; only saved ones can be picked, the server makes the block from what it has saved. */
  steps: Step[];
  /** The steps picked on the canvas. */
  initialSelected: number[];
  /** The draft differs from what is saved. */
  dirty: boolean;
  onClose: () => void;
  /** A block was made, so the list of blocks is out of date. */
  onBlockMade: () => void;
  /** Marks the picked steps as an instance of the new block in the draft. Nothing is created. */
  onReplace: (ref: string, nodes: Map<number, string>) => void;
}

interface Made {
  ref: string;
  label: string;
  warnings: string[];
  nodes: Map<number, string> | null;
}

type Response = ModuleDefinition & { warnings?: string[] };

const isSaved = (step: Step) => step.id > 0;

/**
 * The graph key of each picked step, read from the new manifest, or null when the manifest does not line up with the
 * pick (same count, same names, in step order) and a mark could be put on the wrong step.
 */
function nodeKeys(picked: Step[], manifest: ModuleDefinition['manifest']): Map<number, string> | null {
  const graph = (manifest?.graph as { steps?: { key?: unknown; name?: unknown }[] } | undefined)?.steps;
  if (!Array.isArray(graph) || graph.length !== picked.length) return null;
  const ordered = [...picked].sort((a, b) => a.position - b.position);
  const pairs = ordered.map((step, i) => [step, graph[i]] as const);
  if (pairs.some(([step, node]) => node.name !== step.name || typeof node.key !== 'string')) return null;
  return new Map(pairs.map(([step, node]) => [step.id, node.key as string]));
}

/**
 * Saves a group of the workflow's steps as a composite block. The checklist is the keyboard route to the selection, and
 * the way to change it. Everything the server says back is shown as the text it is.
 */
export function SaveAsBlockDialog({
  projectId,
  workflowId,
  steps,
  initialSelected,
  dirty,
  onClose,
  onBlockMade,
  onReplace,
}: Props) {
  const ordered = [...steps].sort((a, b) => a.position - b.position);
  const [picked, setPicked] = useState(
    () => new Set(initialSelected.filter((id) => ordered.some((s) => s.id === id && isSaved(s)))),
  );
  const [label, setLabel] = useState('');
  const [description, setDescription] = useState('');
  const [problem, setProblem] = useState<string | null>(null);
  const [made, setMade] = useState<Made | null>(null);
  const [busy, setBusy] = useState(false);

  const toggle = (id: number, on: boolean) =>
    setPicked((was) => {
      const next = new Set(was);
      if (on) next.add(id);
      else next.delete(id);
      return next;
    });

  const save = async () => {
    setBusy(true);
    setProblem(null);
    const chosen = ordered.filter((s) => picked.has(s.id));
    try {
      const created = await apiRequest<Response>(fromStepsCompanyProjectModuleDefinitionsPath(projectId), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          workflowId,
          stepIds: chosen.map((s) => s.id),
          label: label.trim(),
          description: description.trim(),
        }),
      });
      setMade({
        ref: created.key,
        label: plainLine(created.label, 80),
        warnings: created.warnings ?? [],
        nodes: nodeKeys(chosen, created.manifest),
      });
      onBlockMade();
    } catch (error) {
      setProblem(error instanceof ApiError || error instanceof Error ? error.message : 'The block was not saved.');
    } finally {
      setBusy(false);
    }
  };

  const ready = !dirty && picked.size > 0 && label.trim() !== '' && !busy;

  return (
    <Modal opened onClose={onClose} title="Save as block" size="lg">
      {made ? (
        <Stack gap="md">
          <Text size="sm">{`Saved as the block ${made.label} (${made.ref}). It is ready to insert from the palette.`}</Text>
          {made.warnings.length > 0 && (
            <Alert color="yellow" title="Check these">
              <ul aria-label="Warnings">
                {made.warnings.map((warning) => (
                  <li key={warning}>{plainLine(warning, 300)}</li>
                ))}
              </ul>
            </Alert>
          )}
          <Text size="sm" c="dimmed">
            The steps stay in the workflow as they are. Replacing the selection only marks them as part of the block, so
            they show as one group on the canvas; nothing is created again.
          </Text>
          <Group justify="flex-end">
            <Button variant="default" onClick={onClose}>
              Close
            </Button>
            {made.nodes && (
              <Button
                onClick={() => {
                  onReplace(made.ref, made.nodes as Map<number, string>);
                  onClose();
                }}
              >
                Replace the selection with the block
              </Button>
            )}
          </Group>
        </Stack>
      ) : (
        <Stack gap="md">
          {dirty && (
            <Alert color="yellow" title="Save the workflow first">
              A block is made from the steps as they are saved, and this workflow has changes that are not saved yet.
            </Alert>
          )}
          {problem && (
            <Alert color="red" role="alert" title="The block was not saved">
              {problem}
            </Alert>
          )}
          <Checkbox.Group
            label="Steps in the block"
            description="Pick up to 20 steps. A step that sends or cannot be undone needs its approval in the block too."
            value={[...picked].map(String)}
            onChange={() => {}}
          >
            <Stack gap="xs" mt="xs">
              {ordered.map((step) => (
                <Checkbox
                  key={step.id}
                  value={String(step.id)}
                  label={isSaved(step) ? plainLine(step.name, 120) : `${plainLine(step.name, 120)} (not saved yet)`}
                  disabled={!isSaved(step)}
                  checked={picked.has(step.id)}
                  onChange={(event) => toggle(step.id, event.currentTarget.checked)}
                />
              ))}
            </Stack>
          </Checkbox.Group>
          <TextInput
            label="Name"
            value={label}
            onChange={(event) => setLabel(event.currentTarget.value)}
            maxLength={120}
          />
          <Textarea
            label="Description"
            value={description}
            onChange={(event) => setDescription(event.currentTarget.value)}
            maxLength={2000}
            autosize
            minRows={2}
          />
          <Group justify="flex-end">
            <Button variant="default" onClick={onClose}>
              Cancel
            </Button>
            <Button onClick={save} disabled={!ready} loading={busy}>
              Save as block
            </Button>
          </Group>
        </Stack>
      )}
    </Modal>
  );
}
