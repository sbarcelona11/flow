import { useCallback, useEffect, useMemo, useState } from 'react';

import type { ModuleBlock } from '@/types/generated';

import { apiRequest } from 'shared/lib/apiFetch';
import { apiV1ProjectBlocksPath } from 'shared/routes';

export interface Blocks {
  status: 'idle' | 'loading' | 'ready' | 'error';
  blocks: ModuleBlock[];
  /** Fetches the list again, for after a block was made. */
  reload?: () => void;
}

/** The reusable blocks of the project's modules, fetched once something in the builder needs them. */
export function useBlocks(projectId: number | null, wanted: boolean): Blocks {
  const [state, setState] = useState<Omit<Blocks, 'reload'>>({ status: 'idle', blocks: [] });
  const [round, setRound] = useState(0);
  const started = state.status !== 'idle';

  useEffect(() => {
    if (!wanted || projectId == null || (started && round === 0)) return;
    setState((was) => ({ status: 'loading', blocks: was.blocks }));
    apiRequest<ModuleBlock[]>(apiV1ProjectBlocksPath(projectId))
      .then((blocks) => setState({ status: 'ready', blocks }))
      .catch(() => setState((was) => ({ status: 'error', blocks: was.blocks })));
    // `started` is read once per round: flipping it must not start another fetch.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [wanted, projectId, round]);

  const reload = useCallback(() => setRound((n) => n + 1), []);
  return useMemo(() => ({ ...state, reload }), [state, reload]);
}

/** A block an action step can be created from: a valid one that wraps an operation. */
export const isActionBlock = (block: ModuleBlock) =>
  block.executor === 'action' && block.status === 'valid' && block.target !== null;

/** A block that inserts as a group of steps: a valid composite. */
export const isCompositeBlock = (block: ModuleBlock) =>
  block.executor === 'composite' && block.status === 'valid' && block.composite !== null;
