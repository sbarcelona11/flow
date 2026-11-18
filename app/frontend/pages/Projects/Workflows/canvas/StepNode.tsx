import { ActionIcon, Menu } from '@mantine/core';
import {
  IconAlertTriangle,
  IconClockHour4,
  IconHandStop,
  IconLink,
  IconPlayerPlay,
  IconSparkles,
} from '@tabler/icons-react';
import { Handle, type NodeProps, Position } from '@xyflow/react';
import { type KeyboardEvent, type MouseEvent, memo, type ReactNode } from 'react';

import type { Step } from '@/types/generated';

import { EFFECT_LABELS } from 'shared/lib/actionEffects';

import { useCanvasActions } from './CanvasActions';
import type { StepNode as StepNodeType, StepNodeData } from './graph';
import { NODE_HEIGHT, NODE_WIDTH } from './layout';
import classes from './WorkflowCanvas.module.css';

const ICONS: Record<Step['kind'], ReactNode> = {
  agent: <IconSparkles size={14} aria-hidden />,
  approval: <IconHandStop size={14} aria-hidden />,
  wait: <IconClockHour4 size={14} aria-hidden />,
  action: <IconPlayerPlay size={14} aria-hidden />,
};

function duration(seconds: number): string {
  if (seconds % 3600 === 0) return `${seconds / 3600} h`;
  if (seconds % 60 === 0) return `${seconds / 60} min`;
  return `${seconds} s`;
}

function summary({ step, blockLabel }: StepNodeData): string {
  const config = step.kindConfig;
  if (step.kind === 'approval') {
    const after = config.timeoutSeconds ? `Times out after ${duration(config.timeoutSeconds)}` : 'No timeout';
    return `${after}, then ${config.onTimeout === 'skip' ? 'skips' : 'fails'}`;
  }
  if (step.kind === 'wait') {
    return config.untilContextKey
      ? `Waits until ${config.untilContextKey}`
      : `Waits ${duration(config.delaySeconds ?? 0)}`;
  }
  if (step.kind === 'action') return blockLabel ?? config.block ?? config.tool ?? 'No target yet';
  const firstLine = (step.instructions ?? '').split('\n').find((line) => line.trim());
  return step.requiredAgentRuntime ?? firstLine?.trim() ?? 'No instructions yet';
}

const portTop = (index: number, count: number) => `${72 + ((index + 1) * 20) / (count + 1)}%`;

function RunAfterItems({ stepId }: { stepId: number }) {
  const { eligible, runAfter } = useCanvasActions();
  const options = eligible(stepId);
  if (options.length === 0) return <Menu.Item closeMenuOnClick>No other step can come first</Menu.Item>;
  return options.map((option) => (
    <Menu.Item key={option.id} onClick={() => runAfter(stepId, option.id)}>
      {option.name}
    </Menu.Item>
  ));
}

// React Flow moves a node on arrow keys and selects it on Enter; the menu keeps those keys for itself.
const keepKeys = (event: KeyboardEvent<HTMLElement>) => event.stopPropagation();
// The dropdown is a portal, but its clicks still bubble through React to the node, which would re-select this step after a menu action selected another.
const keepClicks = (event: MouseEvent<HTMLElement>) => event.stopPropagation();

function StepNodeView({ data, selected }: NodeProps<StepNodeType>) {
  const { editable, addApprovalBefore } = useCanvasActions();
  const { step, kindLabel, problems, ports } = data;
  const effect = step.kind === 'action' ? step.kindConfig.effect : undefined;
  const risky = effect === 'send' || effect === 'irreversible';
  const subSteps = step.kind === 'agent' ? step.subSteps.length : 0;

  return (
    <div className={classes.node} data-kind={step.kind} style={{ width: NODE_WIDTH, minHeight: NODE_HEIGHT }}>
      <Handle
        type="target"
        position={Position.Left}
        id="in"
        isConnectable={editable}
        className={classes.handle}
        data-testid={`handle:${step.id}:in`}
      />
      <Handle
        type="source"
        position={Position.Right}
        id="out"
        isConnectable={editable}
        className={classes.handle}
        data-testid={`handle:${step.id}:out`}
      />
      <div className={classes.nodeHead}>
        <span className={classes.kind}>
          {ICONS[step.kind]}
          {kindLabel}
        </span>
        {risky && effect && <span className={classes.effect}>{EFFECT_LABELS[effect]}</span>}
        {subSteps > 0 && (
          <span className={classes.count}>
            {subSteps} {subSteps === 1 ? 'step' : 'steps'}
          </span>
        )}
        {editable && selected && (
          <div className="nodrag nopan" onKeyDown={keepKeys} onClick={keepClicks}>
            <Menu position="bottom-start" withinPortal>
              <Menu.Target>
                <ActionIcon size="xs" variant="subtle" aria-label={`Run ${step.name} after…`}>
                  <IconLink size={12} aria-hidden />
                </ActionIcon>
              </Menu.Target>
              <Menu.Dropdown>
                <Menu.Label>Run after…</Menu.Label>
                <RunAfterItems stepId={step.id} />
                {risky && (
                  <>
                    <Menu.Divider />
                    <Menu.Item onClick={() => addApprovalBefore(step.id)}>Add approval before</Menu.Item>
                  </>
                )}
              </Menu.Dropdown>
            </Menu>
          </div>
        )}
        {problems.length > 0 && (
          <span className={classes.problems}>
            <IconAlertTriangle size={12} aria-hidden />
            {problems.length}
            <span className="app-visually-hidden">{problems[0].message}</span>
          </span>
        )}
      </div>
      <div className={classes.nodeName}>{step.name}</div>
      <div className={classes.nodeSummary}>{summary(data)}</div>
      {ports && (
        <div className={classes.ports}>
          {[...ports.in.map((p) => ({ ...p, side: 'in' })), ...ports.out.map((p) => ({ ...p, side: 'out' }))].map(
            (port) => (
              <span key={`${port.side}:${port.name}`} className={classes.chip} data-invalid={port.invalid || undefined}>
                {port.side === 'in' ? 'in' : 'out'} {port.name}
                {port.type ? `: ${port.type}` : ''}
                {port.invalid ? ' (mismatch)' : ''}
              </span>
            ),
          )}
        </div>
      )}
      {ports?.in.map((port, i) => (
        <Handle
          key={`in:${port.name}`}
          type="target"
          position={Position.Left}
          id={`in:${port.name}`}
          isConnectable={false}
          className={classes.portHandle}
          style={{ top: portTop(i, ports.in.length) }}
        />
      ))}
      {ports?.out.map((port, i) => (
        <Handle
          key={`out:${port.name}`}
          type="source"
          position={Position.Right}
          id={`out:${port.name}`}
          isConnectable={false}
          className={classes.portHandle}
          style={{ top: portTop(i, ports.out.length) }}
        />
      ))}
    </div>
  );
}

export const StepNodeComponent = memo(StepNodeView);
