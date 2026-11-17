import { useEffect, useState } from 'react';

import type { ActionTarget } from '@/types/generated';

import { apiRequest } from 'shared/lib/apiFetch';
import { apiV1ProjectActionTargetsPath } from 'shared/routes';

export interface ActionTargets {
  status: 'idle' | 'loading' | 'ready' | 'error';
  targets: ActionTarget[];
}

/** The tools an action can call, fetched once the builder first needs them and kept for the session. */
export function useActionTargets(projectId: number | null, wanted: boolean): ActionTargets {
  const [state, setState] = useState<ActionTargets>({ status: 'idle', targets: [] });
  const started = state.status !== 'idle';

  useEffect(() => {
    if (!wanted || started || projectId == null) return;
    setState({ status: 'loading', targets: [] });
    apiRequest<ActionTarget[]>(apiV1ProjectActionTargetsPath(projectId))
      .then((targets) => setState({ status: 'ready', targets }))
      .catch(() => setState({ status: 'error', targets: [] }));
  }, [wanted, started, projectId]);

  return state;
}
