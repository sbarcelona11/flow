import { ActionIcon, Menu, Popover } from '@mantine/core';
import { IconAlertCircle, IconAlertTriangle, IconPlugConnected } from '@tabler/icons-react';
import { Handle, type NodeProps, Position } from '@xyflow/react';
import { type KeyboardEvent, type MouseEvent, memo } from 'react';

import { formatCapCents } from 'shared/lib/budgetCap';

import type { GroupPort } from '../composites';
import { IssueList } from '../IssueList';

import { useCanvasActions } from './CanvasActions';
import type { CompositeNode as CompositeNodeType, CompositeNodeData } from './graph';
import { COMPOSITE_HEIGHT } from './graph';
import { NODE_WIDTH } from './layout';
import classes from './WorkflowCanvas.module.css';

const keepKeys = (event: KeyboardEvent<HTMLElement>) => event.stopPropagation();
const keepClicks = (event: MouseEvent<HTMLElement>) => event.stopPropagation();
const plural = (count: number, word: string) => `${count} ${word}${count === 1 ? '' : 's'}`;
const typeText = (port: GroupPort) => port.type || 'any';

/** Every problem of the inner steps, however the group is drawn: a count that opens the list, each step's own. */
function GroupProblems({ problems }: { problems: CompositeNodeData['problems'] }) {
  const { fixLabel, applyFix } = useCanvasActions();
  const all = problems.flatMap((p) => p.issues);
  if (all.length === 0) return null;
  const errors = all.filter((i) => i.severity === 'error').length;
  const warnings = all.length - errors;
  return (
    <div className={`${classes.problemsSlot} nodrag nopan`} onKeyDown={keepKeys} onClick={keepClicks}>
      <Popover position="bottom-end" width={340} shadow="md" withinPortal trapFocus returnFocus>
        <Popover.Target>
          <button type="button" className={classes.problems}>
            {errors > 0 && (
              <span className={classes.problemCount}>
                <IconAlertCircle size={12} aria-hidden />
                {plural(errors, 'error')}
              </span>
            )}
            {warnings > 0 && (
              <span className={classes.problemCount}>
                <IconAlertTriangle size={12} aria-hidden />
                {plural(warnings, 'warning')}
              </span>
            )}
            <span className="app-visually-hidden">{`: ${all[0].message}`}</span>
          </button>
        </Popover.Target>
        <Popover.Dropdown>
          {problems.map(({ step, issues }) => (
            <div key={step.id}>
              <strong>{step.name}</strong>
              <IssueList
                issues={issues}
                label={`Problems with ${step.name}`}
                fixLabel={fixLabel}
                onFix={(fix) => applyFix(step.id, fix)}
              />
            </div>
          ))}
        </Popover.Dropdown>
      </Popover>
    </div>
  );
}

function PortBindMenu({ instance, port, label }: { instance: string; port: GroupPort; label: string }) {
  const { groupBindingOptions, bindGroupPort, unbindGroupPort } = useCanvasActions();
  const options = groupBindingOptions(instance, port.name);
  return (
    <div className="nodrag nopan" onKeyDown={keepKeys} onClick={keepClicks}>
      <Menu position="bottom-start" withinPortal>
        <Menu.Target>
          <ActionIcon size="xs" variant="subtle" aria-label={`Bind ${port.name} of ${label} to…`}>
            <IconPlugConnected size={12} aria-hidden />
          </ActionIcon>
        </Menu.Target>
        <Menu.Dropdown>
          <Menu.Label>{`Bind ${port.name} to…`}</Menu.Label>
          {options.length === 0 && <Menu.Label>No earlier step has an output port</Menu.Label>}
          {options.map((option) => (
            <Menu.Item
              key={`${option.stepId}:${option.port}`}
              onClick={() => bindGroupPort(instance, port.name, option)}
            >
              {`${option.stepName}: ${option.port} (${option.type ?? 'any'})`}
            </Menu.Item>
          ))}
          {port.connected && (
            <>
              <Menu.Divider />
              <Menu.Item onClick={() => unbindGroupPort(instance, port.name)}>Remove binding</Menu.Item>
            </>
          )}
        </Menu.Dropdown>
      </Menu>
    </div>
  );
}

function PortRow({
  side,
  port,
  instance,
  label,
}: {
  side: 'in' | 'out';
  port: GroupPort;
  instance: string;
  label: string;
}) {
  const { editable, groupPortBindable } = useCanvasActions();
  const unconnected = side === 'in' && port.connected === false;
  return (
    <div className={classes.portRow} data-side={side}>
      <span
        role="group"
        aria-label={`${side === 'in' ? 'Input' : 'Output'} ${port.name}, type ${typeText(port)}${unconnected ? ', not connected' : ''}`}
        className={classes.chip}
      >
        {side} {port.name}: {typeText(port)}
        {unconnected && <span className={classes.notConnected}> not connected</span>}
      </span>
      {side === 'in' && editable && groupPortBindable(instance, port.name) && (
        <PortBindMenu instance={instance} port={port} label={label} />
      )}
    </div>
  );
}

function Chips({ data }: { data: CompositeNodeData }) {
  const { summary, problems } = data;
  return (
    <>
      <span className={classes.kind}>Group</span>
      <span className={classes.count}>{plural(summary.steps.length, 'step')}</span>
      {summary.capCents != null && (
        <span
          role="group"
          aria-label={`Group budget caps up to ${formatCapCents(summary.capCents)}`}
          className={classes.count}
        >
          {`caps up to ${formatCapCents(summary.capCents)}`}
        </span>
      )}
      {summary.newerVersion != null && <span className={classes.count}>{`v${summary.newerVersion} available`}</span>}
      {!summary.known && <span className={classes.count}>block not available</span>}
      <GroupProblems problems={problems} />
    </>
  );
}

function Actions({ data }: { data: CompositeNodeData }) {
  const { editable, toggleGroup, ungroup } = useCanvasActions();
  const { instance, expanded, summary } = data;
  return (
    <div className={`${classes.groupActions} nodrag nopan`} onKeyDown={keepKeys} onClick={keepClicks}>
      <button
        type="button"
        className={classes.groupButton}
        aria-expanded={expanded}
        onClick={() => toggleGroup(instance)}
      >
        <span className="app-visually-hidden">{`${expanded ? 'Collapse' : 'Expand'} ${summary.label}`}</span>
        <span aria-hidden>{expanded ? 'Collapse' : 'Expand'}</span>
      </button>
      {editable && (
        <button type="button" className={classes.groupButton} onClick={() => ungroup(instance)}>
          <span className="app-visually-hidden">{`Ungroup ${summary.label}`}</span>
          <span aria-hidden>Ungroup</span>
        </button>
      )}
    </div>
  );
}

function CompositeNodeView({ data }: NodeProps<CompositeNodeType>) {
  const { summary, expanded, instance } = data;

  if (expanded) {
    return (
      <div className={classes.frame}>
        <div className={classes.frameHead}>
          <span className={classes.nodeName}>{summary.label}</span>
          <Chips data={data} />
          <Actions data={data} />
        </div>
      </div>
    );
  }

  return (
    <div className={classes.composite} style={{ width: NODE_WIDTH, minHeight: COMPOSITE_HEIGHT }}>
      <Handle type="target" position={Position.Left} id="in" isConnectable={false} className={classes.handle} />
      <Handle type="source" position={Position.Right} id="out" isConnectable={false} className={classes.handle} />
      <div className={classes.nodeHead}>
        <Chips data={data} />
      </div>
      <div className={classes.nodeName}>{summary.label}</div>
      <div className={classes.ports}>
        {summary.ports.in.map((port) => (
          <PortRow key={`in:${port.name}`} side="in" port={port} instance={instance} label={summary.label} />
        ))}
        {summary.ports.out.map((port) => (
          <PortRow key={`out:${port.name}`} side="out" port={port} instance={instance} label={summary.label} />
        ))}
      </div>
      <Actions data={data} />
    </div>
  );
}

export const CompositeNodeComponent = memo(CompositeNodeView);
