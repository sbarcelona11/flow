import { Autocomplete, Button, Select, Text, Textarea, TextInput } from '@mantine/core';
import { useState } from 'react';

import type { ActionTarget, Step } from '@/types/generated';

import {
  ACTION_EFFECTS,
  type ActionEffect,
  allowedEffects,
  type Field,
  fieldsFor,
  fromArguments,
  toArguments,
} from './actionArguments';
import { ACTION_OUTPUT_DEFAULT, actionOutputSpecs } from './builderDraft';
import classes from './BuilderPage.module.css';
import type { ActionTargets } from './useActionTargets';

const INPUT_STYLES = {
  input: {
    background: 'transparent',
    border: '1px solid var(--border)',
    borderRadius: 4,
    color: 'var(--text-1)',
    fontSize: 13,
  },
};

const DRIFTED_HINT = 'Changed since approved — review it on the server page';

const EFFECT_LABELS: Record<ActionEffect, string> = {
  read: 'Read',
  write: 'Write',
  send: 'Send',
  irreversible: 'Irreversible',
};

const EFFECT_TEXTS: Record<ActionEffect, string> = {
  read: 'Only looks something up; nothing changes.',
  write: 'Creates or changes data in the connected system.',
  send: 'Sends something to other people, such as a message or an email.',
  irreversible: "Does something that can't be undone, such as deleting data.",
};

export const APPROVAL_WARNING = 'Add an approval step before this action; it will be refused on save otherwise.';

type KindConfig = Step['kindConfig'];

const targetValue = ({
  type,
  mcpServerId,
  tool,
  toolId,
}: Pick<ActionTarget, 'type' | 'mcpServerId' | 'tool' | 'toolId'>) =>
  type === 'wrapper' ? `wrapper:${toolId}` : `mcp:${mcpServerId}:${tool}`;

const configTargetValue = (config: KindConfig): string | null =>
  config.target === 'wrapper' && config.toolId != null
    ? targetValue({ type: 'wrapper', mcpServerId: null, tool: null, toolId: config.toolId })
    : config.target === 'mcp_tool' && config.mcpServerId != null && config.tool
      ? targetValue({ type: 'mcp_tool', mcpServerId: config.mcpServerId, tool: config.tool, toolId: null })
      : null;

function toolOptions(targets: ActionTarget[]) {
  const groups = new Map<string, { group: string; items: { value: string; label: string; disabled: boolean }[] }>();
  for (const target of targets) {
    const key = target.type === 'wrapper' ? 'wrappers' : `server:${target.mcpServerId}`;
    const group = groups.get(key) ?? { group: target.serverName ?? 'Wrappers', items: [] };
    group.items.push({ value: targetValue(target), label: target.name, disabled: target.drifted });
    groups.set(key, group);
  }
  return [...groups.values()];
}

interface ArgumentFieldsProps {
  fields: Field[];
  initial: Record<string, unknown>;
  readOnly: boolean;
  onChange: (args: Record<string, unknown>) => void;
}

function ArgumentFields({ fields, initial, readOnly, onChange }: ArgumentFieldsProps) {
  const [values, setValues] = useState(() => fromArguments(initial, fields));

  if (fields.length === 0) return <div className={classes.consequence}>This tool takes no arguments.</div>;

  const change = (name: string, value: string) => {
    const next = { ...values, [name]: value };
    setValues(next);
    onChange(toArguments(next, fields));
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      {fields.map((field) => {
        const common = {
          label: field.name,
          description: field.description ?? undefined,
          withAsterisk: field.required,
          disabled: readOnly,
          value: values[field.name] ?? '',
          styles: INPUT_STYLES,
        };
        if (field.type === 'json') {
          return (
            <Textarea
              key={field.name}
              {...common}
              autosize
              minRows={2}
              placeholder="JSON, or {{context:key}}"
              onChange={(e) => change(field.name, e.currentTarget.value)}
            />
          );
        }
        if (field.type === 'enum' || field.type === 'boolean') {
          return (
            <Autocomplete
              key={field.name}
              {...common}
              data={field.type === 'boolean' ? ['true', 'false'] : field.options}
              onChange={(value) => change(field.name, value)}
            />
          );
        }
        return (
          <TextInput
            key={field.name}
            {...common}
            placeholder={field.type === 'string' ? undefined : field.type}
            onChange={(e) => change(field.name, e.currentTarget.value)}
          />
        );
      })}
      <div className={classes.consequence}>
        Any value can use {'{{context:key}}'} to take a value the run has stored under that key.
      </div>
    </div>
  );
}

interface ActionStepFieldsProps {
  step: Pick<Step, 'id' | 'kindConfig'>;
  targets: ActionTargets;
  readOnly: boolean;
  hasApproval: boolean;
  onFieldChange: (field: string, value: unknown) => void;
  onAddApproval: () => void;
}

export function ActionStepFields({
  step,
  targets,
  readOnly,
  hasApproval,
  onFieldChange,
  onAddApproval,
}: ActionStepFieldsProps) {
  const config = step.kindConfig;
  const chosen = configTargetValue(config);
  const selected = targets.targets.find((target) => targetValue(target) === chosen) ?? null;
  const effect = (config.effect ?? 'write') as ActionEffect;
  const effects = allowedEffects(selected?.baseEffect ?? ACTION_EFFECTS[0]);
  const needsApproval = effect === 'send' || effect === 'irreversible';
  const driftedNames = new Set(targets.targets.filter((t) => t.drifted).map(targetValue));

  const chooseTool = (value: string | null) => {
    const target = targets.targets.find((t) => targetValue(t) === value);
    if (!target || target.drifted) return;
    onFieldChange('kindConfig', {
      target: target.type,
      ...(target.type === 'wrapper'
        ? { toolId: target.toolId }
        : { mcpServerId: target.mcpServerId, tool: target.tool }),
      arguments: {},
      effect: target.baseEffect,
      outputName: config.outputName ?? ACTION_OUTPUT_DEFAULT,
    });
  };

  const changeOutput = (name: string) => {
    onFieldChange('kindConfig', { ...config, outputName: name });
    onFieldChange('outputAssetSpecs', actionOutputSpecs(name.trim() || ACTION_OUTPUT_DEFAULT));
  };

  if (targets.status === 'error') {
    return <Text size="sm">The tools could not be loaded. Reload the page to try again.</Text>;
  }

  const loading = targets.status !== 'ready';

  return (
    <>
      <label className={classes.fieldLabel}>Tool</label>
      <Select
        data={toolOptions(targets.targets)}
        value={chosen}
        onChange={chooseTool}
        disabled={readOnly || loading}
        placeholder={loading ? 'Loading tools…' : 'Choose a tool'}
        searchable
        allowDeselect={false}
        aria-label="Tool"
        styles={INPUT_STYLES}
        renderOption={({ option }) => (
          <div>
            <div>{option.label}</div>
            {driftedNames.has(option.value) && <div style={{ fontSize: 11 }}>{DRIFTED_HINT}</div>}
          </div>
        )}
      />
      {!loading && chosen && !selected && (
        <div className={classes.consequence}>This tool is no longer available. Choose another one.</div>
      )}
      {selected?.description && <div className={classes.consequence}>{selected.description}</div>}

      {selected && (
        <>
          <div style={{ marginTop: 12 }}>
            <label className={classes.fieldLabel}>Arguments</label>
            <ArgumentFields
              key={chosen}
              fields={fieldsFor(selected.inputSchema)}
              initial={config.arguments ?? {}}
              readOnly={readOnly}
              onChange={(args) => onFieldChange('kindConfig', { ...config, arguments: args })}
            />
          </div>

          <div style={{ marginTop: 12 }}>
            <label className={classes.fieldLabel}>Effect</label>
            <Select
              data={effects.map((value) => ({ value, label: EFFECT_LABELS[value] }))}
              value={effect}
              onChange={(value) => value && onFieldChange('kindConfig', { ...config, effect: value })}
              disabled={readOnly}
              allowDeselect={false}
              aria-label="Effect"
              styles={INPUT_STYLES}
            />
            <div className={classes.consequence}>{EFFECT_TEXTS[effect]}</div>
            {needsApproval && !hasApproval && (
              <div className={classes.consequence} role="alert">
                {APPROVAL_WARNING}
                {!readOnly && (
                  <div style={{ marginTop: 6 }}>
                    <Button size="xs" variant="light" onClick={onAddApproval}>
                      Add an approval before it
                    </Button>
                  </div>
                )}
              </div>
            )}
          </div>
        </>
      )}

      <div style={{ marginTop: 12 }}>
        <TextInput
          label="Output file"
          value={config.outputName ?? ACTION_OUTPUT_DEFAULT}
          onChange={(e) => changeOutput(e.currentTarget.value)}
          disabled={readOnly}
          styles={INPUT_STYLES}
        />
        <div className={classes.consequence}>The result of the call is saved to this file for later steps.</div>
      </div>
    </>
  );
}
