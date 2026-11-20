import { notifications } from '@mantine/notifications';
import { type ReactNode, useCallback, useRef, useState } from 'react';

import type { ModuleBlock, Step } from '@/types/generated';

import { ApiError, apiRequest } from 'shared/lib/apiFetch';
import { plainLine } from 'shared/resources/connectors/reviewText';
import { expandApiV1ProjectBlocksPath } from 'shared/routes';

import { draftCompositeSteps } from './builderDraft';
import { bindingOptions } from './canvas/connections';
import type { Point } from './canvas/layout';
import { type Expansion } from './composites';
import { ConnectInputsDialog } from './ConnectInputsDialog';

interface Options {
  projectId: number | null;
  workflowId: number;
  steps: Step[];
  blocks: ModuleBlock[];
  setSteps: (updater: (steps: Step[]) => Step[]) => void;
  announce: (message: string) => void;
  /** The first step inserted, for the list view to open. */
  onInserted?: (firstStepId: number) => void;
}

interface Pending {
  block: ModuleBlock;
  at: Point | null;
}

/** The draft's own `new-<n>` keys in use, so the block's steps are keyed above them and a binding can name any of them. */
const firstFreeIndex = (steps: Step[]) =>
  Math.max(0, ...steps.flatMap((s) => [s.id, ...s.subSteps.map((x) => x.id)]).map((id) => -id)) + 1;

/**
 * Inserting a composite block: asks for its inputs (skippable), has the server expand it into ordinary steps and puts
 * them in the draft. Nothing is saved; the server checks the steps again at Save and its refusals are shown as they are.
 */
export function useCompositeInsertion({
  projectId,
  workflowId,
  steps,
  blocks,
  setSteps,
  announce,
  onInserted,
}: Options): { start: (block: ModuleBlock, at: Point | null) => void; dialog: ReactNode } {
  const [pending, setPending] = useState<Pending | null>(null);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const latest = useRef({ steps, blocks });
  latest.current = { steps, blocks };

  const run = useCallback(
    async ({ block, at }: Pending, bindings: Record<string, string>, quiet: boolean) => {
      if (projectId == null) return;
      setBusy(true);
      setProblem(null);
      try {
        const expansion = await apiRequest<Expansion>(expandApiV1ProjectBlocksPath(projectId), {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            ref: block.key,
            bindings,
            workflowId,
            firstIndex: firstFreeIndex(latest.current.steps),
            ...(at ? { at: { x: Math.round(at.x), y: Math.round(at.y) } } : {}),
          }),
        });
        const added = draftCompositeSteps(latest.current.steps, expansion, at);
        setSteps((prev) => [...prev, ...added]);
        setPending(null);
        const label = plainLine(block.label, 80);
        announce(`${label} inserted as ${added.length} ${added.length === 1 ? 'step' : 'steps'}`);
        if (expansion.warnings.length > 0)
          notifications.show({ color: 'yellow', message: expansion.warnings.map((w) => plainLine(w, 300)).join(' ') });
        if (added[0]) onInserted?.(added[0].id);
      } catch (error) {
        const message =
          error instanceof ApiError || error instanceof Error ? error.message : 'The block was not inserted.';
        if (!quiet) notifications.show({ color: 'red', message });
        setProblem(message);
      } finally {
        setBusy(false);
      }
    },
    [projectId, workflowId, setSteps, announce, onInserted],
  );

  const start = useCallback(
    (block: ModuleBlock, at: Point | null) => {
      const next = { block, at };
      setProblem(null);
      if (Object.keys(block.composite?.ports.in ?? {}).length === 0) void run(next, {}, false);
      else setPending(next);
    },
    [run],
  );

  const dialog = pending && (
    <ConnectInputsDialog
      key={pending.block.key}
      block={pending.block}
      options={bindingOptions(steps, blocks, null)}
      busy={busy}
      problem={problem}
      onConnect={(bindings) => void run(pending, bindings, true)}
      onClose={() => setPending(null)}
    />
  );

  return { start, dialog };
}
