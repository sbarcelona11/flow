import { IconX } from '@tabler/icons-react';
import { BaseEdge, EdgeLabelRenderer, type EdgeProps, getBezierPath } from '@xyflow/react';

import { useCanvasActions } from './CanvasActions';
import classes from './WorkflowCanvas.module.css';

export function DependencyEdge({
  id,
  sourceX,
  sourceY,
  targetX,
  targetY,
  sourcePosition,
  targetPosition,
  selected,
  markerEnd,
  data,
}: EdgeProps) {
  const { editable, removeEdge } = useCanvasActions();
  const [path, labelX, labelY] = getBezierPath({ sourceX, sourceY, targetX, targetY, sourcePosition, targetPosition });
  const label = (data as { label?: string } | undefined)?.label ?? 'dependency';

  return (
    <>
      <BaseEdge id={id} path={path} markerEnd={markerEnd} />
      {editable && selected && (
        <EdgeLabelRenderer>
          <button
            type="button"
            className={`${classes.edgeButton} nodrag nopan`}
            style={{ transform: `translate(-50%, -50%) translate(${labelX}px, ${labelY}px)` }}
            aria-label={`Remove dependency: ${label}`}
            onClick={() => removeEdge(id)}
          >
            <IconX size={12} aria-hidden />
            Remove dependency
          </button>
        </EdgeLabelRenderer>
      )}
    </>
  );
}
