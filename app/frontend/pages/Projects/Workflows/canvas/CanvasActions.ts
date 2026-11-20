import { createContext, useContext } from 'react';

import type { IssueFix } from '../dataFlow';

import type { BindingOption } from './connections';

export interface CanvasActions {
  editable: boolean;
  /** Steps `stepId` could be made to run after, read when a menu opens. */
  eligible: (stepId: number) => { id: number; name: string }[];
  runAfter: (stepId: number, dependencyId: number) => void;
  removeEdge: (edgeId: string) => void;
  /** Puts a new approval in front of an action, for the actions that send or cannot be undone. */
  addApprovalBefore: (actionId: number) => void;
  /** Out ports `stepId` could be fed from, read when a "Bind to…" menu opens. */
  bindingOptions: (stepId: number) => BindingOption[];
  bind: (stepId: number, argument: string, option: BindingOption) => void;
  unbind: (stepId: number, argument: string) => void;
  /** The label of an issue's fix button, or null to offer none (read-only, or nothing it could act on). */
  fixLabel: (fix: IssueFix) => string | null;
  applyFix: (stepId: number, fix: IssueFix) => void;
  /** Shows or hides the steps of a composite block's instance. This is view state, never saved. */
  toggleGroup: (instance: string) => void;
  /** Clears the provenance of the instance's steps; they stay as ordinary steps. */
  ungroup: (instance: string) => void;
  /** Whether the manifest names an argument that binding this in port can write to. */
  groupPortBindable: (instance: string, port: string) => boolean;
  /** Out ports an in port of the group could be fed from, read when its "Bind to…" menu opens. */
  groupBindingOptions: (instance: string, port: string) => BindingOption[];
  bindGroupPort: (instance: string, port: string, option: BindingOption) => void;
  unbindGroupPort: (instance: string, port: string) => void;
}

const none: CanvasActions = {
  editable: false,
  eligible: () => [],
  runAfter: () => {},
  removeEdge: () => {},
  addApprovalBefore: () => {},
  bindingOptions: () => [],
  bind: () => {},
  unbind: () => {},
  fixLabel: () => null,
  applyFix: () => {},
  toggleGroup: () => {},
  ungroup: () => {},
  groupPortBindable: () => false,
  groupBindingOptions: () => [],
  bindGroupPort: () => {},
  unbindGroupPort: () => {},
};

export const CanvasActionsContext = createContext<CanvasActions>(none);

export const useCanvasActions = () => useContext(CanvasActionsContext);
