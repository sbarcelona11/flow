import '@xyflow/react/dist/style.css';

import { Button, useComputedColorScheme } from '@mantine/core';
import { useReducedMotion } from '@mantine/hooks';
import { notifications } from '@mantine/notifications';
import { IconLayoutDistributeHorizontal, IconPackageExport } from '@tabler/icons-react';
import {
  applyNodeChanges,
  Background,
  type Connection,
  Controls,
  type Edge,
  type EdgeChange,
  type EdgeTypes,
  type AriaLabelConfig,
  type CoordinateExtent,
  MiniMap,
  type NodeChange,
  type NodeTypes,
  Panel,
  ReactFlow,
  ReactFlowProvider,
  useReactFlow,
} from '@xyflow/react';
import { type FocusEvent, type KeyboardEvent, useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';

import type { ModuleBlock, Step } from '@/types/generated';

import { withoutPortBinding, withPortBinding } from '../actionArguments';
import {
  CANVAS_LIMIT,
  ungroup as ungroupSteps,
  withProvenance,
  draftBlockStep,
  draftStep,
  pinAll,
  type StepKind,
  withApprovalBefore,
  withDependency,
  withoutDependency,
  withPositions,
} from '../builderDraft';
import { frameNodeId, groupNodeId, instanceOfNode, instancesOf, membersOf } from '../composites';
import type { IssueFix, WorkflowIssue } from '../dataFlow';
import type { Selection } from '../SessionTreeNav';
import type { Blocks } from '../useBlocks';

import { type CanvasActions, CanvasActionsContext } from './CanvasActions';
import { CanvasPalette } from './CanvasPalette';
import { CompositeNodeComponent } from './CompositeNode';
import {
  type BindingOption,
  bindingOptions,
  bindingRefusalMessage,
  dependencyRefusal,
  dropMessage,
  eligibleDependencies,
  groupPortBindable,
  groupPortTargetStepId,
  type HandleType,
  refusalMessage,
  withGroupPortBinding,
  withoutGroupPortBinding,
} from './connections';
import { DataEdge } from './DataEdge';
import { DependencyEdge } from './DependencyEdge';
import { type CanvasNode, toCanvasGraph } from './graph';
import {
  autoLayout,
  freeSpot,
  LAYER_GAP,
  layoutKey,
  NODE_HEIGHT,
  NODE_WIDTH,
  type Point,
  resolvePositions,
} from './layout';
import { SaveAsBlockDialog } from './SaveAsBlockDialog';
import { StepNodeComponent } from './StepNode';
import classes from './WorkflowCanvas.module.css';

const nodeTypes: NodeTypes = { step: StepNodeComponent, composite: CompositeNodeComponent };
const edgeTypes: EdgeTypes = { dependency: DependencyEdge, data: DataEdge };
const NODE_EXTENT: CoordinateExtent = [
  [-CANVAS_LIMIT, -CANVAS_LIMIT],
  [CANVAS_LIMIT, CANVAS_LIMIT],
];
const ARROW_KEYS = new Set(['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight']);

const MINIMAP_FROM = 30;
const VISIBLE_ONLY_FROM = 60;

interface Props {
  /** Sorted by position. */
  steps: Step[];
  issues: WorkflowIssue[];
  blocks: ModuleBlock[];
  /** Load state of `blocks`, for the palette. */
  blocksStatus?: Blocks['status'];
  actionsEnabled?: boolean;
  /** The palette asks for the blocks when it opens; the builder fetches them lazily. */
  onWantBlocks?: () => void;
  selection: Selection | null;
  readOnly: boolean;
  onSelect: (stepId: number | null) => void;
  /** Draft edits; the builder's own `setSteps`. Ignored while `readOnly`. */
  onStepsChange?: (updater: (steps: Step[]) => Step[]) => void;
  /** Opens the builder's confirm modal; a step is never deleted without it. */
  onRequestDelete?: (stepId: number) => void;
  announce?: (message: string) => void;
  /** Changes when the builder removed a step, so focus can return to the canvas. */
  focusSignal?: number;
  /** The builder's fix buttons, so a fix offered in the list view is offered on the node too. */
  fixLabel?: (fix: IssueFix) => string | null;
  onFix?: (stepId: number, fix: IssueFix) => void;
  /** With the workflow's ids, the toolbar offers Save as block, made from the saved steps. */
  projectId?: number | null;
  workflowId?: number;
  /** The draft differs from what is saved. */
  dirty?: boolean;
  /** Inserts a composite block at a canvas position; the builder asks for its inputs first. */
  onInsertComposite?: (block: ModuleBlock, at: Point) => void;
  /** A block was made, so the builder's list of blocks is out of date. */
  onBlocksChanged?: () => void;
}

const noop = () => {};

const isGroupEdge = (edge: Pick<Edge, 'id'>) => edge.id.startsWith('grp:');
const isDependencyEdge = (edge: Pick<Edge, 'id'>) => edge.id.startsWith('dep:') || isGroupEdge(edge);

function edgeLabel(edge: Edge, names: Map<string, string>): string {
  const from = names.get(edge.source) ?? 'a step';
  const to = names.get(edge.target) ?? 'a step';
  if (isDependencyEdge(edge)) return `${to} runs after ${from}`;
  const invalid = (edge.data as { invalid?: boolean } | undefined)?.invalid;
  return `${from} feeds ${to}${invalid ? ', output type does not match' : ''}`;
}

const newInstance = (): string =>
  globalThis.crypto?.randomUUID?.() ??
  'xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx'.replace(/x/g, () => Math.floor(Math.random() * 16).toString(16));

const round = (p: Point): Point => ({ x: Math.round(p.x), y: Math.round(p.y) });

/** The local nodes for a new graph: React Flow's measurements and an in-flight drag survive it. */
function mergeNodes(next: CanvasNode[], previous: CanvasNode[]): CanvasNode[] {
  const before = new Map(previous.map((n) => [n.id, n]));
  return next.map((node) => {
    const old = before.get(node.id);
    if (!old) return node;
    if (old.dragging) return { ...node, position: old.position, dragging: true, measured: old.measured };
    return old.measured ? { ...node, measured: old.measured } : node;
  });
}

function Canvas({
  steps,
  issues,
  blocks,
  blocksStatus = 'idle',
  actionsEnabled = false,
  onWantBlocks = noop,
  selection,
  readOnly,
  onSelect,
  onStepsChange,
  onRequestDelete,
  announce,
  focusSignal = 0,
  fixLabel = () => null,
  onFix = noop,
  projectId = null,
  workflowId,
  dirty = false,
  onInsertComposite,
  onBlocksChanged = noop,
}: Props) {
  const reducedMotion = useReducedMotion();
  const colorScheme = useComputedColorScheme('light');
  const { fitView, screenToFlowPosition } = useReactFlow();
  const helpId = useId();
  const selectedId = selection?.sessionId ?? null;
  const editable = !readOnly && onStepsChange != null;
  const say = useCallback((message: string) => announce?.(message), [announce]);

  const structure = layoutKey(steps);
  // Layout depends on structure alone, so renaming a step or editing instructions does not re-run it.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const positions = useMemo(() => resolvePositions(steps), [structure]);

  // Which composite instances show their steps, and which steps are picked for Save as block. Both are view state.
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(() => new Set());
  const [picked, setPicked] = useState<ReadonlySet<number>>(() => new Set());
  const [saveOpen, setSaveOpen] = useState(false);

  const graph = useMemo(
    () => toCanvasGraph({ steps, issues, blocks, selectedId, readOnly: !editable, expanded, positions }),
    [steps, issues, blocks, selectedId, editable, expanded, positions],
  );

  // Event handlers read the latest values here, so the context and callbacks below keep their identity.
  const latest = useRef({ steps, positions, blocks, groups: graph.groups, expanded });
  useEffect(() => {
    latest.current = { steps, positions, blocks, groups: graph.groups, expanded };
  });

  const graphNodes = useMemo<CanvasNode[]>(() => {
    const groups = instancesOf(steps);
    const mark = <N extends CanvasNode>(node: N, on: boolean): N =>
      on
        ? { ...node, className: classes.picked, ariaLabel: `${node.ariaLabel ?? ''}, picked for Save as block` }
        : node;
    const stepNodes = graph.nodes.map((n) => mark(n, picked.has(Number(n.id))));
    const groupNodes = graph.groups.map((n) => {
      const instance = instanceOfNode(n.id) as string;
      const members = groups.get(instance) ?? [];
      return mark(n, !n.data.expanded && members.length > 0 && members.every((s) => picked.has(s.id)));
    });
    return [...groupNodes.filter((n) => n.data.expanded), ...stepNodes, ...groupNodes.filter((n) => !n.data.expanded)];
  }, [graph, picked, steps]);

  // Nodes are local React Flow state so a drag never touches the draft; it is written once, when the drag ends.
  const [nodes, setNodes] = useState<CanvasNode[]>(graphNodes);
  const [adopted, setAdopted] = useState(graphNodes);
  if (adopted !== graphNodes) {
    setAdopted(graphNodes);
    setNodes((current) => mergeNodes(graphNodes, current));
  }
  const nodesRef = useRef(nodes);
  useEffect(() => {
    nodesRef.current = nodes;
  });

  const nameOf = useCallback((id: number) => latest.current.steps.find((s) => s.id === id)?.name ?? 'A step', []);

  const commitPositions = useCallback(
    (moved: Map<number, Point>) => {
      if (!onStepsChange || moved.size === 0) return;
      const target = new Map([...moved].map(([id, p]) => [id, round(p)]));
      const { positions: resolved } = latest.current;
      const changed = [...target].filter(([id, p]) => {
        const was = resolved.get(id);
        return !was || was.x !== p.x || was.y !== p.y;
      });
      if (changed.length === 0) return;
      onStepsChange((prev) => withPositions(pinAll(prev, resolved), target));
      say(changed.length === 1 ? `${nameOf(changed[0][0])} moved` : `${changed.length} steps moved`);
    },
    [onStepsChange, say, nameOf],
  );

  /** Where each step goes when the given nodes are at the given positions: a group moves all of its steps by its own offset. */
  const movesOf = useCallback((moved: { id: string; position: Point }[]) => {
    const result = new Map<number, Point>();
    const { steps: current, positions: resolved, groups } = latest.current;
    for (const { id, position } of moved) {
      const instance = instanceOfNode(id);
      if (instance === null) {
        result.set(Number(id), position);
        continue;
      }
      const origin = groups.find((g) => g.id === id)?.position;
      if (!origin) continue;
      for (const member of membersOf(current, instance)) {
        const at = resolved.get(member.id);
        if (at) result.set(member.id, { x: at.x + position.x - origin.x, y: at.y + position.y - origin.y });
      }
    }
    return result;
  }, []);

  const dragging = useRef(false);
  const keyMoved = useRef(new Set<string>());
  // A click with Shift held picks a step for Save as block; it never opens the step in the editor.
  const shiftHeld = useRef(false);

  const handleNodesChange = useCallback(
    (changes: NodeChange<CanvasNode>[]) => {
      setNodes((current) => applyNodeChanges(changes, current));
      for (const change of changes) {
        if (change.type === 'select' && change.selected && !shiftHeld.current && instanceOfNode(change.id) === null)
          onSelect(Number(change.id));
        if (change.type === 'position' && change.position && !dragging.current) keyMoved.current.add(change.id);
      }
    },
    [onSelect],
  );

  // One position per key press, written on key-up; the arrow keys themselves are React Flow's.
  const handleKeyUp = useCallback(
    (event: { key: string }) => {
      if (!ARROW_KEYS.has(event.key) || keyMoved.current.size === 0) return;
      const moved = nodesRef.current.filter((node) => keyMoved.current.has(node.id));
      keyMoved.current.clear();
      commitPositions(movesOf(moved));
    },
    [commitPositions, movesOf],
  );

  const handleDragStop = useCallback(
    (_event: unknown, _node: unknown, dragged: CanvasNode[]) => {
      dragging.current = false;
      commitPositions(movesOf(dragged));
    },
    [commitPositions, movesOf],
  );

  const runAfter = useCallback(
    (stepId: number, dependencyId: number) => {
      const current = latest.current.steps;
      const refusal = dependencyRefusal(current, stepId, dependencyId);
      if (refusal) {
        const message = refusalMessage(refusal, nameOf(stepId), nameOf(dependencyId));
        notifications.show({ color: 'red', message });
        say(message);
        return;
      }
      onStepsChange?.((prev) => withDependency(prev, stepId, dependencyId) ?? prev);
      say(`${nameOf(stepId)} now runs after ${nameOf(dependencyId)}`);
    },
    [onStepsChange, say, nameOf],
  );

  const handleConnect = useCallback(
    (connection: Connection) => runAfter(Number(connection.target), Number(connection.source)),
    [runAfter],
  );

  // A drop React Flow judged invalid never reaches onConnect. Only the reason is shown here; nothing is edited.
  const handleConnectEnd = useCallback(
    (
      _event: unknown,
      state: {
        isValid: boolean | null;
        fromNode: { id: string } | null;
        toNode: { id: string } | null;
        fromHandle: { type: HandleType } | null;
        toHandle: { type: HandleType } | null;
      },
    ) => {
      if (state.isValid === true || !state.fromNode || !state.toNode || !state.fromHandle || !state.toHandle) return;
      const message = dropMessage(latest.current.steps, {
        fromType: state.fromHandle.type,
        toType: state.toHandle.type,
        fromId: Number(state.fromNode.id),
        toId: Number(state.toNode.id),
      });
      if (!message) return;
      notifications.show({ color: 'red', message });
      say(message);
    },
    [say],
  );

  const isValidConnection = useCallback(
    (connection: { source: string; target: string }) =>
      dependencyRefusal(latest.current.steps, Number(connection.target), Number(connection.source)) === null,
    [],
  );

  const refocus = useRef(false);
  const removeEdges = useCallback(
    (edgeIds: string[]) => {
      const pairs = edgeIds
        .map((id) => /^dep:(-?\d+)->(-?\d+)$/.exec(id))
        .filter((m): m is RegExpExecArray => m !== null)
        .map((m) => ({ from: Number(m[1]), to: Number(m[2]) }));
      const bindings = edgeIds
        .map((id) => /^data:(-?\d+)\.[^.>]+->(-?\d+)\.(.+)$/.exec(id))
        .filter((m): m is RegExpExecArray => m !== null)
        .map((m) => ({ from: Number(m[1]), to: Number(m[2]), argument: m[3] }));
      if (pairs.length === 0 && bindings.length === 0) return;
      onStepsChange?.((prev) =>
        bindings.reduce(
          (acc, { to, argument }) => withoutPortBinding(acc, to, argument),
          pairs.reduce((acc, { from, to }) => withoutDependency(acc, to, from), prev),
        ),
      );
      refocus.current = true;
      for (const { from, to } of pairs) say(`${nameOf(to)} no longer runs after ${nameOf(from)}`);
      for (const { from, to, argument } of bindings)
        say(`${nameOf(to)} no longer reads ${argument} from ${nameOf(from)}`);
    },
    [onStepsChange, say, nameOf],
  );

  const bind = useCallback(
    (stepId: number, argument: string, option: { stepId: number; port: string; file?: string }) => {
      const binding = { from: option.stepId, port: option.port, file: option.file, to: stepId, argument };
      const current = latest.current.steps;
      if (!withPortBinding(current, binding)) {
        const message = bindingRefusalMessage(current, binding);
        notifications.show({ color: 'red', message });
        return;
      }
      onStepsChange?.((prev) => withPortBinding(prev, binding) ?? prev);
      say(`${nameOf(stepId)} now reads ${argument} from ${nameOf(option.stepId)}: ${option.port}`);
    },
    [onStepsChange, say, nameOf],
  );

  const unbind = useCallback(
    (stepId: number, argument: string) => {
      onStepsChange?.((prev) => withoutPortBinding(prev, stepId, argument));
      say(`${nameOf(stepId)} no longer reads ${argument} from another step`);
    },
    [onStepsChange, say, nameOf],
  );

  const [selectedEdgeId, setSelectedEdgeId] = useState<string | null>(null);
  const handleEdgesChange = useCallback((changes: EdgeChange[]) => {
    for (const change of changes) {
      if (change.type === 'select')
        setSelectedEdgeId((current) => (change.selected ? change.id : current === change.id ? null : current));
    }
  }, []);

  if (selectedEdgeId !== null && !graph.edges.some((e) => e.id === selectedEdgeId)) setSelectedEdgeId(null);

  // React Flow's own delete key listens on the whole document, so it would act from any button on the
  // page. Here the key counts only inside the canvas, and a node is deleted through the builder's confirm modal.
  const handleKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (!editable || event.defaultPrevented || (event.key !== 'Delete' && event.key !== 'Backspace')) return;
    const target = event.target as HTMLElement;
    if (target.closest('input, textarea, select, [contenteditable="true"], .react-flow__panel')) return;
    const nodeId = target.closest('.react-flow__node')?.getAttribute('data-id');
    const edgeId = target.closest('.react-flow__edge')?.getAttribute('data-id') ?? (nodeId ? null : selectedEdgeId);
    if (edgeId) {
      event.preventDefault();
      removeEdges([edgeId]);
      return;
    }
    const doomed = nodeId ?? nodesRef.current.find((n) => n.selected && instanceOfNode(n.id) === null)?.id;
    // A group is never deleted as one; Ungroup it, then remove the steps.
    if (!doomed || instanceOfNode(doomed) !== null) return;
    event.preventDefault();
    onRequestDelete?.(Number(doomed));
  };

  const pendingFocus = useRef<string | null>(null);

  const placeNew = useCallback(
    (leftOf: Point | null, rightOf: Point | null): Point => {
      const occupied = nodesRef.current.map((n) => n.position);
      if (rightOf) return freeSpot({ x: rightOf.x + NODE_WIDTH + LAYER_GAP, y: rightOf.y }, occupied);
      if (leftOf) return freeSpot({ x: leftOf.x - NODE_WIDTH - LAYER_GAP, y: leftOf.y }, occupied);
      const rect = regionRef.current?.getBoundingClientRect();
      const centre = screenToFlowPosition({
        x: (rect?.left ?? 0) + (rect?.width ?? 0) / 2,
        y: (rect?.top ?? 0) + (rect?.height ?? 0) / 2,
      });
      return freeSpot({ x: centre.x - NODE_WIDTH / 2, y: centre.y - NODE_HEIGHT / 2 }, occupied);
    },
    [screenToFlowPosition],
  );

  /** Adds the step the palette entry makes, after the selected node when there is one, and selects and focuses it. */
  const addFromPalette = useCallback(
    (make: (current: Step[], at: Point) => Step) => {
      if (!onStepsChange) return;
      const { steps: current, positions: resolved } = latest.current;
      const after = nodesRef.current.find((n) => n.id === String(selectedId));
      const step = make(current, placeNew(null, after?.position ?? null));
      onStepsChange((prev) => {
        const next = [...pinAll(prev, resolved), step];
        return after ? (withDependency(next, step.id, Number(after.id)) ?? next) : next;
      });
      pendingFocus.current = String(step.id);
      onSelect(step.id);
      say(`${step.name} added${after ? `, runs after ${nameOf(Number(after.id))}` : ''}`);
    },
    [onStepsChange, selectedId, placeNew, onSelect, say, nameOf],
  );

  const addApprovalBefore = useCallback(
    (actionId: number) => {
      if (!onStepsChange) return;
      const { steps: current, positions: resolved } = latest.current;
      const result = withApprovalBefore(pinAll(current, resolved), actionId);
      if (!result) return;
      const at = placeNew(resolved.get(actionId) ?? null, null);
      const { approval } = result;
      onStepsChange((prev) => {
        const made = withApprovalBefore(pinAll(prev, resolved), actionId);
        return made ? withPositions(made.steps, new Map([[made.approval.id, at]])) : prev;
      });
      pendingFocus.current = String(approval.id);
      onSelect(approval.id);
      say(`${approval.name} added before ${nameOf(actionId)}`);
    },
    [onStepsChange, placeNew, onSelect, say, nameOf],
  );

  const groupLabel = useCallback(
    (instance: string) =>
      latest.current.groups.find((g) => instanceOfNode(g.id) === instance)?.data.summary.label ?? 'The group',
    [],
  );

  const toggleGroup = useCallback(
    (instance: string) => {
      const opening = !latest.current.expanded.has(instance);
      setExpanded((was) => {
        const next = new Set(was);
        if (opening) next.add(instance);
        else next.delete(instance);
        return next;
      });
      pendingFocus.current = opening ? frameNodeId(instance) : groupNodeId(instance);
      say(`${groupLabel(instance)} ${opening ? 'expanded' : 'collapsed'}`);
    },
    [say, groupLabel],
  );

  const ungroup = useCallback(
    (instance: string) => {
      const first = membersOf(latest.current.steps, instance)[0];
      const label = groupLabel(instance);
      onStepsChange?.((prev) => ungroupSteps(prev, instance));
      setExpanded((was) => {
        const next = new Set(was);
        next.delete(instance);
        return next;
      });
      if (first) pendingFocus.current = String(first.id);
      say(`${label} ungrouped. Its steps stay in the workflow.`);
    },
    [onStepsChange, say, groupLabel],
  );

  const bindGroupPort = useCallback(
    (instance: string, port: string, option: BindingOption) => {
      const { steps: current, blocks: known } = latest.current;
      const label = groupLabel(instance);
      if (!withGroupPortBinding(current, known, instance, port, option)) {
        const message = `${label} cannot read ${port} from ${option.stepName}: that would make the workflow loop back on itself, or the step cannot read step outputs`;
        notifications.show({ color: 'red', message });
        say(message);
        return;
      }
      onStepsChange?.((prev) => withGroupPortBinding(prev, latest.current.blocks, instance, port, option) ?? prev);
      say(`${label} now reads ${port} from ${option.stepName}: ${option.port}`);
    },
    [onStepsChange, say, groupLabel],
  );

  const unbindGroupPort = useCallback(
    (instance: string, port: string) => {
      onStepsChange?.((prev) => withoutGroupPortBinding(prev, latest.current.blocks, instance, port));
      say(`${groupLabel(instance)} no longer reads ${port} from another step`);
    },
    [onStepsChange, say, groupLabel],
  );

  const actions = useMemo<CanvasActions>(
    () => ({
      editable,
      eligible: (stepId) => eligibleDependencies(latest.current.steps, stepId).map((s) => ({ id: s.id, name: s.name })),
      runAfter,
      removeEdge: (edgeId) => removeEdges([edgeId]),
      addApprovalBefore,
      bindingOptions: (stepId) => bindingOptions(latest.current.steps, latest.current.blocks, stepId),
      bind,
      unbind,
      fixLabel: editable ? fixLabel : () => null,
      applyFix: onFix,
      toggleGroup,
      ungroup,
      groupPortBindable: (instance, port) =>
        groupPortBindable(latest.current.steps, latest.current.blocks, instance, port),
      groupBindingOptions: (instance, port) => {
        const { steps: current, blocks: known } = latest.current;
        const target = groupPortTargetStepId(current, known, instance, port);
        if (target === null) return [];
        const own = new Set(membersOf(current, instance).map((s) => s.id));
        return bindingOptions(current, known, target).filter((option) => !own.has(option.stepId));
      },
      bindGroupPort,
      unbindGroupPort,
    }),
    [
      editable,
      runAfter,
      removeEdges,
      addApprovalBefore,
      bind,
      unbind,
      fixLabel,
      onFix,
      toggleGroup,
      ungroup,
      bindGroupPort,
      unbindGroupPort,
    ],
  );

  const names = new Map([
    ...steps.map((s) => [String(s.id), s.name] as const),
    ...graph.groups.map((g) => [g.id, g.data.summary.label] as const),
  ]);
  const decorated = graph.edges.map((edge) => {
    const label = edgeLabel(edge, names);
    const invalid = (edge.data as { invalid?: boolean } | undefined)?.invalid;
    return {
      ...edge,
      type: isDependencyEdge(edge) ? 'dependency' : 'data',
      ariaLabel: label,
      animated: false,
      deletable: editable && !isGroupEdge(edge),
      selected: edge.id === selectedEdgeId,
      // An edge to a group stands for several steps; it is changed by expanding the group.
      selectable: !isGroupEdge(edge),
      className: invalid ? classes.edgeInvalid : undefined,
      data: { ...edge.data, label },
    } satisfies Edge;
  });
  // The edges change only when their ids, labels, validity or selection do, not on every keystroke in a step.
  const edgesKey = decorated
    .map((e) => `${e.id}|${e.ariaLabel}|${e.selected}|${e.className ?? ''}|${e.deletable}`)
    .join('\n');
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const edges = useMemo<Edge[]>(() => decorated, [edgesKey]);

  /** Picks the steps a node stands for, or lets them go when they are all picked already. */
  const togglePick = useCallback(
    (nodeId: string) => {
      const instance = instanceOfNode(nodeId);
      const ids = instance === null ? [Number(nodeId)] : membersOf(latest.current.steps, instance).map((s) => s.id);
      setPicked((was) => {
        const next = new Set(was);
        const all = ids.every((id) => next.has(id));
        for (const id of ids) {
          if (all) next.delete(id);
          else next.add(id);
        }
        return next;
      });
      const total = ids.length;
      say(`${total === 1 ? nameOf(ids[0]) : groupLabel(instance ?? '')} picked for Save as block, or let go`);
    },
    [say, nameOf, groupLabel],
  );

  const handleNodeClick = (event: { shiftKey: boolean }, node: { id: string }) => {
    if (event.shiftKey && editable) {
      togglePick(node.id);
      return;
    }
    if (picked.size > 0) setPicked(new Set());
    if (instanceOfNode(node.id) === null) onSelect(Number(node.id));
  };

  const canSaveAsBlock = editable && actionsEnabled && projectId != null && workflowId != null;

  const [tidied, setTidied] = useState(0);
  const tidyUp = () => {
    onStepsChange?.((prev) => withPositions(prev, new Map([...autoLayout(prev)].map(([id, p]) => [id, round(p)]))));
    setTidied((n) => n + 1);
    say('Layout tidied');
  };
  useEffect(() => {
    if (tidied > 0) void fitView({ duration: reducedMotion ? 0 : 200 });
  }, [tidied, fitView, reducedMotion]);

  // Off-screen nodes are not in the DOM, so they would drop out of the Tab order. While focus is
  // inside the canvas every node is rendered.
  const [focusWithin, setFocusWithin] = useState(false);
  const regionRef = useRef<HTMLDivElement>(null);
  const handleBlur = (event: FocusEvent<HTMLElement>) => {
    if (!event.currentTarget.contains(event.relatedTarget)) setFocusWithin(false);
  };

  // Removing the focused node or edge drops focus to the page; it goes back to the canvas region.
  const idsKey = steps.map((s) => s.id).join(',');
  useEffect(() => {
    const lost = !document.activeElement || document.activeElement === document.body;
    if (refocus.current || (focusWithin && lost)) regionRef.current?.focus();
    refocus.current = false;
  }, [idsKey, edgesKey, focusWithin]);
  useEffect(() => {
    const id = pendingFocus.current;
    if (id === null) return;
    const element = Array.from(regionRef.current?.querySelectorAll<HTMLElement>('.react-flow__node') ?? []).find(
      (node) => node.dataset.id === id,
    );
    if (!element) return;
    element.focus();
    pendingFocus.current = null;
  }, [nodes]);
  useEffect(() => {
    if (focusSignal > 0) regionRef.current?.focus();
  }, [focusSignal]);

  const nodeHelp = editable
    ? 'Press Enter or Space to select this step. Then arrow keys move it, and Delete asks to remove it.'
    : 'Press Enter or Space to select this step.';
  const ariaLabelConfig = useMemo<Partial<AriaLabelConfig>>(
    () => ({
      // React Flow shows `default` when its keyboard support is off and `keyboardDisabled` when it is on, so both say the same.
      'node.a11yDescription.default': nodeHelp,
      'node.a11yDescription.keyboardDisabled': nodeHelp,
      // Our own live region announces the move once the key is released.
      'node.a11yDescription.ariaLiveMessage': () => '',
      'edge.a11yDescription.default': editable
        ? 'Press Enter or Space to select this connection. A dependency can then be removed with Delete.'
        : 'Press Enter or Space to select this connection.',
    }),
    [editable, nodeHelp],
  );

  return (
    <div
      ref={regionRef}
      tabIndex={-1}
      role="region"
      aria-label="Workflow canvas"
      aria-describedby={helpId}
      className={classes.region}
      onFocus={() => setFocusWithin(true)}
      onBlur={handleBlur}
      onMouseDownCapture={(event) => {
        shiftHeld.current = event.shiftKey;
      }}
      onClickCapture={(event) => {
        shiftHeld.current = event.shiftKey;
      }}
    >
      <p id={helpId} className="app-visually-hidden">
        {editable
          ? 'Tab moves between steps. Enter selects the focused step and opens it in the editor. With a step selected, arrow keys move it, Delete removes it after you confirm, and the Run after button next to its name connects it to another step. Select a connection and press Delete to remove it.'
          : 'Tab moves between steps. Enter opens the focused step in the editor.'}
      </p>
      <CanvasActionsContext.Provider value={actions}>
        <ReactFlow
          nodes={nodes}
          edges={edges}
          nodeTypes={nodeTypes}
          edgeTypes={edgeTypes}
          colorMode={colorScheme}
          nodesDraggable={editable}
          nodesConnectable={editable}
          elementsSelectable
          deleteKeyCode={null}
          nodeExtent={NODE_EXTENT}
          ariaLabelConfig={ariaLabelConfig}
          fitView
          fitViewOptions={{ duration: 0 }}
          minZoom={0.1}
          onlyRenderVisibleElements={graph.nodes.length > VISIBLE_ONLY_FROM && !focusWithin}
          onKeyDown={handleKeyDown}
          onKeyUp={handleKeyUp}
          onNodesChange={handleNodesChange}
          onEdgesChange={handleEdgesChange}
          onNodeClick={handleNodeClick}
          onNodeDragStart={() => {
            dragging.current = true;
          }}
          onNodeDragStop={handleDragStop}
          onConnect={handleConnect}
          onConnectEnd={handleConnectEnd}
          isValidConnection={isValidConnection}
          proOptions={{ hideAttribution: true }}
        >
          <Background />
          <Controls
            showInteractive={false}
            aria-label="Canvas controls"
            fitViewOptions={{ duration: reducedMotion ? 0 : 200 }}
          />
          {graph.nodes.length > MINIMAP_FROM && <MiniMap pannable zoomable ariaLabel="Workflow overview" />}
          {editable && (
            <Panel position="top-left">
              <CanvasPalette
                actionsEnabled={actionsEnabled}
                blocks={{ status: blocksStatus, blocks }}
                onWantBlocks={onWantBlocks}
                onAdd={(kind: StepKind) => addFromPalette((current, at) => draftStep(current, '', kind, at))}
                onAddBlock={(block) => addFromPalette((current, at) => draftBlockStep(current, block, at))}
                onAddComposite={
                  onInsertComposite
                    ? (block) => {
                        const after = nodesRef.current.find((n) => n.id === String(selectedId));
                        onInsertComposite(block, placeNew(null, after?.position ?? null));
                      }
                    : undefined
                }
                readOnly={!editable}
              />
            </Panel>
          )}
          {editable && (
            <Panel position="top-right" className={classes.tidy}>
              {canSaveAsBlock && (
                <>
                  {picked.size > 0 && (
                    <span
                      className={classes.pickedNote}
                    >{`${picked.size} ${picked.size === 1 ? 'step' : 'steps'} picked`}</span>
                  )}
                  <Button
                    size="xs"
                    variant="default"
                    mr="xs"
                    leftSection={<IconPackageExport size={14} aria-hidden />}
                    onClick={() => setSaveOpen(true)}
                  >
                    Save as block
                  </Button>
                </>
              )}
              <Button
                size="xs"
                variant="default"
                leftSection={<IconLayoutDistributeHorizontal size={14} aria-hidden />}
                onClick={tidyUp}
              >
                Tidy up
              </Button>
            </Panel>
          )}
        </ReactFlow>
      </CanvasActionsContext.Provider>
      {saveOpen && canSaveAsBlock && (
        <SaveAsBlockDialog
          projectId={projectId as number}
          workflowId={workflowId as number}
          steps={steps}
          initialSelected={[...picked]}
          dirty={dirty}
          onClose={() => setSaveOpen(false)}
          onBlockMade={onBlocksChanged}
          onReplace={(ref, nodes) => {
            const instance = newInstance();
            onStepsChange?.((prev) => withProvenance(prev, ref, instance, nodes));
            setPicked(new Set());
            say(`${nodes.size} ${nodes.size === 1 ? 'step is' : 'steps are'} now marked as part of the block`);
          }}
        />
      )}
    </div>
  );
}

export default function WorkflowCanvas(props: Props) {
  return (
    <ReactFlowProvider>
      <Canvas {...props} />
    </ReactFlowProvider>
  );
}
