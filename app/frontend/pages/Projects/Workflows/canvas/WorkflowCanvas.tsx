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
  MiniMap,
  type NodeChange,
  type NodeTypes,
  Panel,
  ReactFlow,
  ReactFlowProvider,
  useReactFlow,
} from '@xyflow/react';
import { type FocusEvent, useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';

import type { ModuleBlock, Step } from '@/types/generated';

import { pinAll, withDependency, withoutDependency, withPositions } from '../builderDraft';
import type { WorkflowIssue } from '../dataFlow';
import type { Selection } from '../SessionTreeNav';

import { type CanvasActions, CanvasActionsContext } from './CanvasActions';
import { dependencyRefusal, eligibleDependencies, refusalMessage } from './connections';
import { DependencyEdge } from './DependencyEdge';
import { type StepNode as StepNodeType, toCanvasGraph } from './graph';
import { autoLayout, layoutKey, type Point, resolvePositions } from './layout';
import { StepNodeComponent } from './StepNode';
import classes from './WorkflowCanvas.module.css';

const nodeTypes: NodeTypes = { step: StepNodeComponent };
const edgeTypes: EdgeTypes = { dependency: DependencyEdge };
const DELETE_KEYS = ['Backspace', 'Delete'];
const ARROW_KEYS = new Set(['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight']);

const MINIMAP_FROM = 30;
const VISIBLE_ONLY_FROM = 60;

interface Props {
  /** Sorted by position. */
  steps: Step[];
  issues: WorkflowIssue[];
  blocks: ModuleBlock[];
  selection: Selection | null;
  readOnly: boolean;
  onSelect: (stepId: number | null) => void;
  /** Draft edits; the builder's own `setSteps`. Ignored while `readOnly`. */
  onStepsChange?: (updater: (steps: Step[]) => Step[]) => void;
  /** Opens the builder's confirm modal; a step is never deleted without it. */
  onRequestDelete?: (stepId: number) => void;
  announce?: (message: string) => void;
}

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
  selection,
  readOnly,
  onSelect,
  onStepsChange,
  onRequestDelete,
  announce,
}: Props) {
  const reducedMotion = useReducedMotion();
  const colorScheme = useComputedColorScheme('light');
  const { fitView } = useReactFlow();
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

  // A drop React Flow judged invalid never reaches onConnect, so the reason is given here.
  const handleConnectEnd = useCallback(
    (
      _event: unknown,
      state: { isValid: boolean | null; fromNode: { id: string } | null; toNode: { id: string } | null },
    ) => {
      if (state.isValid !== false || !state.fromNode || !state.toNode) return;
      runAfter(Number(state.toNode.id), Number(state.fromNode.id));
    },
    [runAfter],
  );

  const isValidConnection = useCallback(
    (connection: { source: string; target: string }) =>
      dependencyRefusal(latest.current.steps, Number(connection.target), Number(connection.source)) === null,
    [],
  );

  const removeDependencies = useCallback(
    (edgeIds: string[]) => {
      const pairs = edgeIds
        .map((id) => /^dep:(-?\d+)->(-?\d+)$/.exec(id))
        .filter((m): m is RegExpExecArray => m !== null)
        .map((m) => ({ from: Number(m[1]), to: Number(m[2]) }));
      if (pairs.length === 0) return;
      onStepsChange?.((prev) => pairs.reduce((acc, { from, to }) => withoutDependency(acc, to, from), prev));
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

  // Deleting always goes through the builder: a node through its confirm modal, an edge as a dependency edit.
  const handleBeforeDelete = useCallback(
    async ({ nodes: doomed, edges: cut }: { nodes: { id: string }[]; edges: { id: string }[] }) => {
      if (doomed.length > 0) onRequestDelete?.(Number(doomed[0].id));
      else removeDependencies(cut.map((e) => e.id));
      return false;
    },
    [onRequestDelete, removeDependencies],
  );

  const actions = useMemo<CanvasActions>(
    () => ({
      editable,
      eligible: (stepId) => eligibleDependencies(latest.current.steps, stepId).map((s) => ({ id: s.id, name: s.name })),
      runAfter,
      removeEdge: (edgeId) => removeDependencies([edgeId]),
    }),
    [editable, runAfter, removeDependencies],
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
  const handleBlur = (event: FocusEvent<HTMLElement>) => {
    if (!event.currentTarget.contains(event.relatedTarget)) setFocusWithin(false);
  };

  return (
    <div role="region" aria-label="Workflow canvas" aria-describedby={helpId} className={classes.region}>
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
          deleteKeyCode={editable ? DELETE_KEYS : null}
          fitView
          fitViewOptions={{ duration: 0 }}
          minZoom={0.1}
          onlyRenderVisibleElements={graph.nodes.length > VISIBLE_ONLY_FROM && !focusWithin}
          onFocus={() => setFocusWithin(true)}
          onBlur={handleBlur}
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
          onBeforeDelete={handleBeforeDelete}
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
