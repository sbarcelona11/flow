import { Text } from '@mantine/core';
import type { ComponentProps } from 'react';

import type { Step } from '@/types/generated';

import type { StepKind } from './builderDraft';
import classes from './BuilderPage.module.css';
import type { IssueFix } from './dataFlow';
import { SessionEditorPanel } from './SessionEditorPanel';
import type { Selection } from './SessionTreeNav';
import { StepEditorPanel } from './StepEditorPanel';

type SessionPanelProps = ComponentProps<typeof SessionEditorPanel>;
type AssetSpec = Step['outputAssetSpecs'][number];

interface Props extends Pick<
  SessionPanelProps,
  | 'agents'
  | 'tools'
  | 'toolGroups'
  | 'skills'
  | 'mcpServers'
  | 'assets'
  | 'repositories'
  | 'configItems'
  | 'agentModels'
  | 'readOnly'
  | 'references'
  | 'issues'
  | 'fixLabel'
  | 'available'
  | 'actionsEnabled'
  | 'actionTargets'
  | 'blocks'
  | 'projectId'
  | 'onInsertReference'
> {
  stepCount: number;
  sortedSteps: Step[];
  selection: Selection | null;
  selectedSession: Step | null;
  selectedSubStep: Step['subSteps'][number] | null;
  onStepFieldChange: (stepId: number, field: string, value: unknown) => void;
  onKindChange: (stepId: number, kind: StepKind) => void;
  onAssetSpecsChange: (stepId: number, field: 'inputAssetSpecs' | 'outputAssetSpecs', specs: AssetSpec[]) => void;
  onFix: (stepId: number, fix: IssueFix) => void;
  onOutputRenamed: (stepId: number, before: string, after: string) => void;
  onAddApprovalBefore: (stepId: number) => void;
  onSubStepFieldChange: (sessionId: number, subStepId: number, field: string, value: unknown) => void;
}

/** The editor of the selected step, shared by the list view and the canvas view. */
export function StepEditorArea({
  stepCount,
  sortedSteps,
  selection,
  selectedSession,
  selectedSubStep,
  issues,
  onStepFieldChange,
  onKindChange,
  onAssetSpecsChange,
  onFix,
  onOutputRenamed,
  onAddApprovalBefore,
  onSubStepFieldChange,
  ...shared
}: Props) {
  return (
    <div className={classes.editorArea}>
      {selection && selectedSession ? (
        selection.mode === 'session' ? (
          <SessionEditorPanel
            key={selectedSession.id}
            step={selectedSession}
            allSteps={sortedSteps}
            issues={issues}
            onFieldChange={(field, value) => onStepFieldChange(selectedSession.id, field, value)}
            onKindChange={(kind) => onKindChange(selectedSession.id, kind)}
            onAssetSpecsChange={(field, specs) => onAssetSpecsChange(selectedSession.id, field, specs)}
            onFix={(fix) => onFix(selectedSession.id, fix)}
            onOutputRenamed={(before, after) => onOutputRenamed(selectedSession.id, before, after)}
            onAddApprovalBefore={() => onAddApprovalBefore(selectedSession.id)}
            {...shared}
          />
        ) : selectedSubStep ? (
          <StepEditorPanel
            key={selectedSubStep.id}
            step={selectedSubStep}
            readOnly={shared.readOnly}
            onFieldChange={(field, value) => onSubStepFieldChange(selectedSession.id, selectedSubStep.id, field, value)}
          />
        ) : null
      ) : (
        <div className={classes.emptyState}>
          <Text style={{ fontSize: 48 }}>🔧</Text>
          <Text size="lg" fw={600} style={{ color: 'var(--text-1)' }}>
            {stepCount === 0 ? 'No sessions yet' : 'Select a session to configure'}
          </Text>
          <Text size="sm" style={{ color: 'var(--text-2)' }}>
            {stepCount === 0
              ? 'Add your first session to get started'
              : 'Click on a session in the sidebar to edit its configuration'}
          </Text>
        </div>
      )}
    </div>
  );
}
