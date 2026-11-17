import { useEffect, useState } from 'react';

import type { ModuleBlock } from '@/types/generated';

import { apiRequest } from 'shared/lib/apiFetch';
import { apiV1ProjectBlocksPath } from 'shared/routes';

export interface Blocks {
  status: 'idle' | 'loading' | 'ready' | 'error';
  blocks: ModuleBlock[];
}

/** The reusable blocks of the project's modules, fetched once something in the builder needs them. */
export function useBlocks(projectId: number | null, wanted: boolean): Blocks {
  const [state, setState] = useState<Blocks>({ status: 'idle', blocks: [] });
  const started = state.status !== 'idle';

  useEffect(() => {
    if (!wanted || started || projectId == null) return;
    setState({ status: 'loading', blocks: [] });
    apiRequest<ModuleBlock[]>(apiV1ProjectBlocksPath(projectId))
      .then((blocks) => setState({ status: 'ready', blocks }))
      .catch(() => setState({ status: 'error', blocks: [] }));
  }, [wanted, started, projectId]);

  return state;
}

/** A block an action step can be created from: a valid one that wraps an operation. */
export const isActionBlock = (block: ModuleBlock) =>
  block.executor === 'action' && block.status === 'valid' && block.target !== null;
