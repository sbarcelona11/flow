import { Popover } from '@mantine/core';
import { IconAlertCircle, IconAlertTriangle } from '@tabler/icons-react';
import type { KeyboardEvent, MouseEvent } from 'react';

import type { WorkflowIssue } from '../dataFlow';
import { IssueList } from '../IssueList';

import { useCanvasActions } from './CanvasActions';
import classes from './WorkflowCanvas.module.css';

const keepKeys = (event: KeyboardEvent<HTMLElement>) => event.stopPropagation();
const keepClicks = (event: MouseEvent<HTMLElement>) => event.stopPropagation();

const plural = (count: number, word: string) => `${count} ${word}${count === 1 ? '' : 's'}`;

interface NodeProblemsProps {
  stepId: number;
  name: string;
  problems: WorkflowIssue[];
}

/** The node's problem badge: a button that lists every issue for the step, each with the builder's one-click fix. */
export function NodeProblems({ stepId, name, problems }: NodeProblemsProps) {
  const { fixLabel, applyFix } = useCanvasActions();
  const errors = problems.filter((p) => p.severity === 'error').length;
  const warnings = problems.length - errors;

  return (
    <div className={`${classes.problemsSlot} nodrag nopan`} onKeyDown={keepKeys} onClick={keepClicks}>
      <Popover position="bottom-end" width={320} shadow="md" withinPortal trapFocus returnFocus>
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
            <span className="app-visually-hidden">{`: ${problems[0].message}`}</span>
          </button>
        </Popover.Target>
        <Popover.Dropdown>
          <IssueList
            issues={problems}
            label={`Problems with ${name}`}
            fixLabel={fixLabel}
            onFix={(fix) => applyFix(stepId, fix)}
          />
        </Popover.Dropdown>
      </Popover>
    </div>
  );
}
