import { Link } from '@inertiajs/react';
import { Autocomplete, Badge, Button, Select, Text, Textarea, TextInput } from '@mantine/core';
import { modals } from '@mantine/modals';
import { useState } from 'react';

import type { ActionTarget, ModuleBlock, Step } from '@/types/generated';

import { EFFECT_LABELS, EFFECT_TEXTS } from 'shared/lib/actionEffects';
import { companyProjectMCPServerPath } from 'shared/routes';
import { SchemaForm } from 'shared/ui/SchemaForm';

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
import type { Blocks } from './useBlocks';

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

export const APPROVAL_WARNING = 'Add an approval step before this action; it will be refused on save otherwise.';

type KindConfig = Step['kindConfig'];

type TargetKey = Pick<ActionTarget, 'type' | 'mcpServerId' | 'tool' | 'toolId' | 'apiOperationId'>;

const NO_TARGET: TargetKey = { type: 'mcp_tool', mcpServerId: null, tool: null, toolId: null, apiOperationId: null };

const targetValue = ({ type, mcpServerId, tool, toolId, apiOperationId }: TargetKey) =>
  type === 'wrapper'
    ? `wrapper:${toolId}`
    : type === 'rest_operation'
      ? `rest:${apiOperationId}`
      : `mcp:${mcpServerId}:${tool}`;

const configTargetValue = (config: KindConfig): string | null =>
  config.target === 'wrapper' && config.toolId != null
    ? targetValue({ ...NO_TARGET, type: 'wrapper', toolId: config.toolId })
    : config.target === 'rest_operation' && config.apiOperationId != null
      ? targetValue({ ...NO_TARGET, type: 'rest_operation', apiOperationId: config.apiOperationId })
      : config.target === 'mcp_tool' && config.mcpServerId != null && config.tool
        ? targetValue({ ...NO_TARGET, mcpServerId: config.mcpServerId, tool: config.tool })
        : null;

const groupKey = (target: ActionTarget) =>
  target.type === 'wrapper'
    ? 'wrappers'
    : target.type === 'rest_operation'
      ? `rest:${target.serverName}`
      : `server:${target.mcpServerId}`;

const targetLabel = (target: ActionTarget) =>
  target.type === 'rest_operation' && target.httpMethod && target.path
    ? `${target.httpMethod} ${target.path}`
    : target.name;

function toolOptions(targets: ActionTarget[]) {
  const groups = new Map<string, { group: string; items: { value: string; label: string; disabled: boolean }[] }>();
  for (const target of targets) {
    const key = groupKey(target);
    const group = groups.get(key) ?? { group: target.serverName ?? 'Wrappers', items: [] };
    group.items.push({ value: targetValue(target), label: targetLabel(target), disabled: target.drifted });
    groups.set(key, group);
  }
  return [...groups.values()];
}

interface ArgumentFieldsProps {
  fields: Field[];
  initial: Record<string, unknown>;
  readOnly: boolean;
  noun: 'tool' | 'operation';
  onChange: (args: Record<string, unknown>) => void;
}

function ArgumentFields({ fields, initial, readOnly, noun, onChange }: ArgumentFieldsProps) {
  const [values, setValues] = useState(() => fromArguments(initial, fields));

  if (fields.length === 0) return <div className={classes.consequence}>This {noun} takes no arguments.</div>;

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

function PortChips({ label, ports }: { label: string; ports: Record<string, string> | undefined }) {
  const entries = Object.entries(ports ?? {});
  if (entries.length === 0) return null;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 4, flexWrap: 'wrap' }}>
      <span style={{ fontSize: 11 }}>{label}</span>
      {entries.map(([name, type]) => (
        <Badge key={name} size="xs" variant="light" radius="sm" style={{ textTransform: 'none' }}>
          {`${name}: ${type}`}
        </Badge>
      ))}
    </div>
  );
}

function BlockSummary({ reference, block }: { reference: string; block: ModuleBlock | null }) {
  return (
    <div style={{ marginBottom: 12 }}>
      <div className={classes.fieldLabel}>Block</div>
      <div className={classes.consequence}>{block ? `${block.label} (${reference})` : `Block ${reference}`}</div>
      {block?.description && <div className={classes.consequence}>{block.description}</div>}
      {block && (
        <>
          <PortChips label="Takes" ports={block.ports.in} />
          <PortChips label="Gives" ports={block.ports.out} />
        </>
      )}
    </div>
  );
}

const DETACH_TEXT = "This step will keep calling the same operation but won't follow the block any more.";

const withoutBlock = (config: KindConfig): KindConfig => {
  const rest = { ...config };
  delete rest.block;
  return rest;
};

interface ActionStepFieldsProps {
  step: Pick<Step, 'id' | 'kindConfig'>;
  targets: ActionTargets;
  blocks: Blocks;
  projectId: number | null;
  readOnly: boolean;
  hasApproval: boolean;
  onFieldChange: (field: string, value: unknown) => void;
  onAddApproval: () => void;
}

export function ActionStepFields({
  step,
  targets,
  blocks,
  projectId,
  readOnly,
  hasApproval,
  onFieldChange,
  onAddApproval,
}: ActionStepFieldsProps) {
  const config = step.kindConfig;
  const blockRef = config.block ?? null;
  const block = blockRef ? (blocks.blocks.find((b) => b.key === blockRef) ?? null) : null;
  const chosen = configTargetValue(config);
  const selected = targets.targets.find((target) => targetValue(target) === chosen) ?? null;
  const effect = (config.effect ?? 'write') as ActionEffect;
  const baseEffect = block?.effect ?? selected?.baseEffect ?? ACTION_EFFECTS[0];
  const effects = allowedEffects(baseEffect);
  const belowBase = !effects.includes(effect);
  const needsApproval = effect === 'send' || effect === 'irreversible';
  const driftedNames = new Set(targets.targets.filter((t) => t.drifted).map(targetValue));
  const operations = new Map(
    targets.targets.filter((t) => t.type === 'rest_operation').map((t) => [targetValue(t), t] as const),
  );

  const chooseTool = (value: string | null) => {
    const target = targets.targets.find((t) => targetValue(t) === value);
    if (!target || target.drifted) return;
    onFieldChange('kindConfig', {
      target: target.type,
      ...(target.type === 'wrapper'
        ? { toolId: target.toolId }
        : target.type === 'rest_operation'
          ? { apiOperationId: target.apiOperationId }
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
      {blockRef && <BlockSummary reference={blockRef} block={block} />}
      {blockRef && !readOnly && (
        <div style={{ marginBottom: 12 }}>
          {blocks.status === 'ready' && (!block || block.status !== 'valid') && (
            <div className={classes.consequence} role="alert">
              {block?.reason ?? 'This block is invalid or archived, so the step cannot use it.'} Detach the step from it
              to keep calling the operation.
            </div>
          )}
          <Button
            size="xs"
            variant="light"
            onClick={() =>
              modals.openConfirmModal({
                title: 'Detach from block',
                children: <Text size="sm">{DETACH_TEXT}</Text>,
                labels: { confirm: 'Detach', cancel: 'Cancel' },
                onConfirm: () => onFieldChange('kindConfig', withoutBlock(config)),
              })
            }
          >
            Detach from block
          </Button>
        </div>
      )}
      <label className={classes.fieldLabel}>Tool</label>
      <Select
        data={toolOptions(targets.targets)}
        value={chosen}
        onChange={chooseTool}
        disabled={readOnly || loading || blockRef !== null}
        placeholder={loading ? 'Loading tools…' : 'Choose a tool'}
        searchable
        allowDeselect={false}
        aria-label="Tool"
        styles={INPUT_STYLES}
        renderOption={({ option }) => {
          const operation = operations.get(option.value);
          return (
            <div>
              {operation?.httpMethod && operation.path ? (
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <Badge size="xs" variant="light" radius="sm">
                    {operation.httpMethod}
                  </Badge>
                  <span>{operation.path}</span>
                </div>
              ) : (
                <div>{option.label}</div>
              )}
              {operation && <div style={{ fontSize: 11 }}>{operation.name}</div>}
              {driftedNames.has(option.value) && <div style={{ fontSize: 11 }}>{DRIFTED_HINT}</div>}
            </div>
          );
        }}
      />
      {!loading && chosen && !selected && (
        <div className={classes.consequence}>
          {config.target === 'rest_operation'
            ? 'This operation is no longer available.'
            : 'This tool is no longer available. Choose another one.'}
        </div>
      )}
      {selected?.drifted && (
        <div className={classes.consequence} role="alert">
          This tool changed since it was approved. Review the change on the{' '}
          {projectId != null && selected.mcpServerId != null ? (
            <Link href={companyProjectMCPServerPath(projectId, selected.mcpServerId)}>server page</Link>
          ) : (
            'server page'
          )}{' '}
          before running this action.
        </div>
      )}
      {selected?.description && <div className={classes.consequence}>{selected.description}</div>}

      {selected && (
        <>
          <div style={{ marginTop: 12 }}>
            <label className={classes.fieldLabel}>Arguments</label>
            {blockRef && !block ? (
              <div className={classes.consequence} role="status">
                {blocks.status === 'error'
                  ? 'The block could not be loaded.'
                  : blocks.status === 'ready'
                    ? 'This block is no longer available.'
                    : 'Loading the block…'}
              </div>
            ) : block ? (
              <SchemaForm
                schema={block.config}
                value={config.arguments ?? {}}
                readOnly={readOnly}
                onChange={(args) => onFieldChange('kindConfig', { ...config, arguments: args })}
              />
            ) : (
              <ArgumentFields
                key={chosen}
                fields={fieldsFor(selected.inputSchema)}
                initial={config.arguments ?? {}}
                readOnly={readOnly}
                noun={selected.type === 'rest_operation' ? 'operation' : 'tool'}
                onChange={(args) => onFieldChange('kindConfig', { ...config, arguments: args })}
              />
            )}
          </div>

          <div style={{ marginTop: 12 }}>
            <label className={classes.fieldLabel}>Effect</label>
            <Select
              data={(belowBase ? [effect, ...effects] : effects).map((value) => ({
                value,
                label: EFFECT_LABELS[value],
              }))}
              value={effect}
              onChange={(value) => value && onFieldChange('kindConfig', { ...config, effect: value })}
              disabled={readOnly}
              allowDeselect={false}
              aria-label="Effect"
              styles={INPUT_STYLES}
            />
            <div className={classes.consequence}>{EFFECT_TEXTS[effect]}</div>
            {belowBase && (
              <div className={classes.consequence}>
                Below the {selected.type === 'rest_operation' ? 'operation' : 'tool'}&apos;s own effect ({baseEffect}).
                Raise it to {baseEffect} or higher.
              </div>
            )}
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
          disabled={readOnly || blockRef !== null}
          styles={INPUT_STYLES}
        />
        <div className={classes.consequence}>The result of the call is saved to this file for later steps.</div>
      </div>
    </>
  );
}
