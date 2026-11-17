import '@xyflow/react/dist/style.css';

import { useComputedColorScheme } from '@mantine/core';
import { useReducedMotion } from '@mantine/hooks';
import {
  Background,
  Controls,
  type Edge,
  MiniMap,
  type NodeChange,
  type NodeTypes,
  ReactFlow,
  ReactFlowProvider,
  type ReactFlowInstance,
} from '@xyflow/react';
import { useCallback, useId, useMemo } from 'react';

import type { ModuleBlock, Step } from '@/types/generated';

import type { WorkflowIssue } from '../dataFlow';
import type { Selection } from '../SessionTreeNav';

import { type StepNode as StepNodeType, toCanvasGraph } from './graph';
import { layoutKey, NODE_HEIGHT, NODE_WIDTH, resolvePositions } from './layout';
import { StepNodeComponent } from './StepNode';
import classes from './WorkflowCanvas.module.css';

const nodeTypes: NodeTypes = { step: StepNodeComponent };

const MINIMAP_FROM = 30;
const VISIBLE_ONLY_FROM = 60;

interface Props {
  /** Sorted by position. */
  steps: Step[];
  issues: WorkflowIssue[];
  blocks: ModuleBlock[];
  selection: Selection | null;
  readOnly: true;
  onSelect: (stepId: number | null) => void;
}

function edgeLabel(edge: Edge, names: Map<string, string>): string {
  const from = names.get(edge.source) ?? 'a step';
  const to = names.get(edge.target) ?? 'a step';
  if (!edge.id.startsWith('data:')) return `${to} runs after ${from}`;
  const invalid = (edge.data as { invalid?: boolean } | undefined)?.invalid;
  return `${from} feeds ${to}${invalid ? ', output type does not match' : ''}`;
}

function Canvas({ steps, issues, blocks, selection, onSelect }: Props) {
  const reducedMotion = useReducedMotion();
  const colorScheme = useComputedColorScheme('light');
  const helpId = useId();
  const selectedId = selection?.sessionId ?? null;

  const structure = layoutKey(steps);
  // Layout depends on structure alone, so renaming a step or editing instructions does not re-run it.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const positions = useMemo(() => resolvePositions(steps), [structure]);

  const graph = useMemo(
    () => toCanvasGraph({ steps, issues, blocks, selectedId, readOnly: true, positions }),
    [steps, issues, blocks, selectedId, positions],
  );

  const edges = useMemo<Edge[]>(() => {
    const names = new Map(steps.map((s) => [String(s.id), s.name]));
    return graph.edges.map((edge) => ({
      ...edge,
      ariaLabel: edgeLabel(edge, names),
      animated: false,
      className: (edge.data as { invalid?: boolean } | undefined)?.invalid ? classes.edgeInvalid : undefined,
    }));
  }, [graph.edges, steps]);

  const handleNodesChange = useCallback(
    (changes: NodeChange<StepNodeType>[]) => {
      for (const change of changes) {
        if (change.type === 'select' && change.selected) onSelect(Number(change.id));
      }
    },
    [onSelect],
  );

  const handleInit = useCallback(
    (instance: ReactFlowInstance<StepNodeType, Edge>) => {
      const selected = graph.nodes.find((n) => n.selected);
      if (!selected) return;
      void instance.setCenter(selected.position.x + NODE_WIDTH / 2, selected.position.y + NODE_HEIGHT / 2, {
        zoom: 1,
        duration: reducedMotion ? 0 : 300,
      });
    },
    [graph.nodes, reducedMotion],
  );

  return (
    <div role="region" aria-label="Workflow canvas" aria-describedby={helpId} className={classes.region}>
      <p id={helpId} className="app-visually-hidden">
        Tab moves between steps. Enter opens the focused step in the editor.
      </p>
      <ReactFlow
        nodes={graph.nodes}
        edges={edges}
        nodeTypes={nodeTypes}
        colorMode={colorScheme}
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable
        deleteKeyCode={null}
        fitView={selectedId == null}
        fitViewOptions={{ duration: reducedMotion ? 0 : 200 }}
        onlyRenderVisibleElements={graph.nodes.length > VISIBLE_ONLY_FROM}
        onNodesChange={handleNodesChange}
        onNodeClick={(_, node) => onSelect(Number(node.id))}
        onInit={handleInit}
        proOptions={{ hideAttribution: true }}
      >
        <Background />
        <Controls showInteractive={false} aria-label="Canvas controls" />
        {graph.nodes.length > MINIMAP_FROM && <MiniMap pannable zoomable aria-label="Workflow overview" />}
      </ReactFlow>
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
