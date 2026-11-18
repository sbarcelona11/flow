import '@xyflow/react/dist/style.css';

import { Button, useComputedColorScheme } from '@mantine/core';
import { useReducedMotion } from '@mantine/hooks';
import { notifications } from '@mantine/notifications';
import { IconLayoutDistributeHorizontal } from '@tabler/icons-react';
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

import {
  CANVAS_LIMIT,
  draftBlockStep,
  draftStep,
  pinAll,
  type StepKind,
  withApprovalBefore,
  withDependency,
  withoutDependency,
  withPositions,
} from '../builderDraft';
import type { WorkflowIssue } from '../dataFlow';
import type { Selection } from '../SessionTreeNav';
import type { Blocks } from '../useBlocks';

import { type CanvasActions, CanvasActionsContext } from './CanvasActions';
import { CanvasPalette } from './CanvasPalette';
import { dependencyRefusal, dropMessage, eligibleDependencies, type HandleType, refusalMessage } from './connections';
import { DependencyEdge } from './DependencyEdge';
import { type StepNode as StepNodeType, toCanvasGraph } from './graph';
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
import { StepNodeComponent } from './StepNode';
import classes from './WorkflowCanvas.module.css';

const nodeTypes: NodeTypes = { step: StepNodeComponent };
const edgeTypes: EdgeTypes = { dependency: DependencyEdge };
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
}

const noop = () => {};

const isDependencyEdge = (edge: Pick<Edge, 'id'>) => edge.id.startsWith('dep:');

function edgeLabel(edge: Edge, names: Map<string, string>): string {
  const from = names.get(edge.source) ?? 'a step';
  const to = names.get(edge.target) ?? 'a step';
  if (isDependencyEdge(edge)) return `${to} runs after ${from}`;
  const invalid = (edge.data as { invalid?: boolean } | undefined)?.invalid;
  return `${from} feeds ${to}${invalid ? ', output type does not match' : ''}`;
}

const round = (p: Point): Point => ({ x: Math.round(p.x), y: Math.round(p.y) });

/** The local nodes for a new graph: React Flow's measurements and an in-flight drag survive it. */
function mergeNodes(next: StepNodeType[], previous: StepNodeType[]): StepNodeType[] {
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

  const graph = useMemo(
    () => toCanvasGraph({ steps, issues, blocks, selectedId, readOnly: !editable, positions }),
    [steps, issues, blocks, selectedId, editable, positions],
  );

  // Event handlers read the latest values here, so the context and callbacks below keep their identity.
  const latest = useRef({ steps, positions });
  useEffect(() => {
    latest.current = { steps, positions };
  });

  // Nodes are local React Flow state so a drag never touches the draft; it is written once, when the drag ends.
  const [nodes, setNodes] = useState<StepNodeType[]>(graph.nodes);
  const [adopted, setAdopted] = useState(graph.nodes);
  if (adopted !== graph.nodes) {
    setAdopted(graph.nodes);
    setNodes((current) => mergeNodes(graph.nodes, current));
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

  const dragging = useRef(false);
  const keyMoved = useRef(new Set<string>());

  const handleNodesChange = useCallback(
    (changes: NodeChange<StepNodeType>[]) => {
      setNodes((current) => applyNodeChanges(changes, current));
      for (const change of changes) {
        if (change.type === 'select' && change.selected) onSelect(Number(change.id));
        if (change.type === 'position' && change.position && !dragging.current) keyMoved.current.add(change.id);
      }
    },
    [onSelect],
  );

  // One position per key press, written on key-up; the arrow keys themselves are React Flow's.
  const handleKeyUp = useCallback(
    (event: { key: string }) => {
      if (!ARROW_KEYS.has(event.key) || keyMoved.current.size === 0) return;
      const moved = new Map<number, Point>();
      for (const node of nodesRef.current) if (keyMoved.current.has(node.id)) moved.set(Number(node.id), node.position);
      keyMoved.current.clear();
      commitPositions(moved);
    },
    [commitPositions],
  );

  const handleDragStop = useCallback(
    (_event: unknown, _node: unknown, dragged: StepNodeType[]) => {
      dragging.current = false;
      commitPositions(new Map(dragged.map((n) => [Number(n.id), n.position])));
    },
    [commitPositions],
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
  const removeDependencies = useCallback(
    (edgeIds: string[]) => {
      const pairs = edgeIds
        .map((id) => /^dep:(-?\d+)->(-?\d+)$/.exec(id))
        .filter((m): m is RegExpExecArray => m !== null)
        .map((m) => ({ from: Number(m[1]), to: Number(m[2]) }));
      if (pairs.length === 0) return;
      onStepsChange?.((prev) => pairs.reduce((acc, { from, to }) => withoutDependency(acc, to, from), prev));
      refocus.current = true;
      for (const { from, to } of pairs) say(`${nameOf(to)} no longer runs after ${nameOf(from)}`);
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
      removeDependencies([edgeId]);
      return;
    }
    const doomed = nodeId ?? nodesRef.current.find((n) => n.selected)?.id;
    if (!doomed) return;
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

  const actions = useMemo<CanvasActions>(
    () => ({
      editable,
      eligible: (stepId) => eligibleDependencies(latest.current.steps, stepId).map((s) => ({ id: s.id, name: s.name })),
      runAfter,
      removeEdge: (edgeId) => removeDependencies([edgeId]),
      addApprovalBefore,
    }),
    [editable, runAfter, removeDependencies, addApprovalBefore],
  );

  const names = new Map(steps.map((s) => [String(s.id), s.name]));
  const decorated = graph.edges.map((edge) => {
    const label = edgeLabel(edge, names);
    const invalid = (edge.data as { invalid?: boolean } | undefined)?.invalid;
    return {
      ...edge,
      type: isDependencyEdge(edge) ? 'dependency' : undefined,
      ariaLabel: label,
      animated: false,
      deletable: editable && isDependencyEdge(edge),
      selected: edge.id === selectedEdgeId,
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
          onNodeClick={(_, node) => onSelect(Number(node.id))}
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
                readOnly={!editable}
              />
            </Panel>
          )}
          {editable && (
            <Panel position="top-right" className={classes.tidy}>
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
