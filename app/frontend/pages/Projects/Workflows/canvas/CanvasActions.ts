import { createContext, useContext } from 'react';

export interface CanvasActions {
  editable: boolean;
  /** Steps `stepId` could be made to run after, read when a menu opens. */
  eligible: (stepId: number) => { id: number; name: string }[];
  runAfter: (stepId: number, dependencyId: number) => void;
  removeEdge: (edgeId: string) => void;
  /** Puts a new approval in front of an action, for the actions that send or cannot be undone. */
  addApprovalBefore: (actionId: number) => void;
}

const none: CanvasActions = {
  editable: false,
  eligible: () => [],
  runAfter: () => {},
  removeEdge: () => {},
  addApprovalBefore: () => {},
};

export const CanvasActionsContext = createContext<CanvasActions>(none);

export const useCanvasActions = () => useContext(CanvasActionsContext);
