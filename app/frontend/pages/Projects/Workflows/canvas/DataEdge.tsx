import { IconX } from '@tabler/icons-react';
import { BaseEdge, EdgeLabelRenderer, type EdgeProps, getBezierPath } from '@xyflow/react';

import { useCanvasActions } from './CanvasActions';
import classes from './WorkflowCanvas.module.css';

/** A bound block port. A type mismatch is written on the edge, not only drawn red and dashed. */
export function DataEdge({
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
  const { label, invalid } = (data ?? {}) as { label?: string; invalid?: boolean };
  const removable = editable && selected;

  return (
    <>
      <BaseEdge id={id} path={path} markerEnd={markerEnd} />
      {(invalid || removable) && (
        <EdgeLabelRenderer>
          <div
            className="nodrag nopan"
            style={{
              position: 'absolute',
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 4,
              transform: `translate(-50%, -50%) translate(${labelX}px, ${labelY}px)`,
            }}
          >
            {invalid && <span className={classes.edgeLabel}>Type mismatch</span>}
            {removable && (
              <button
                type="button"
                className={classes.edgeButtonInline}
                aria-label={`Remove binding: ${label ?? 'data'}`}
                onClick={() => removeEdge(id)}
              >
                <IconX size={12} aria-hidden />
                Remove binding
              </button>
            )}
          </div>
        </EdgeLabelRenderer>
      )}
    </>
  );
}
